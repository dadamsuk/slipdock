defmodule Slipdock.Meetings.VoiceprintsTest do
  @moduledoc """
  Voiceprints by consent (#548): off unless an admin turns them on; each
  person enrols only themselves, from their own recording or a meeting where
  their voice was confirmed, with the consent wording recorded; only the
  embedding is kept; deleting stops later captures using it; the export has
  it; and a match is one more piece of attribution evidence.
  """
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures
  import Slipdock.MeetingsFixtures

  alias Slipdock.{Meetings, Repo, Settings}
  alias Slipdock.Meetings.{Speakers, Voice, Voiceprint, VoiceprintConsent, Voiceprints}

  @sam [1.0, 0.0, 0.0]
  @ollie [0.0, 1.0, 0.0]

  setup do
    meetings_on()
    owner = user_fixture("owner@example.com")
    {:ok, owner} = Slipdock.Accounts.update_profile(owner, %{"name" => "Priya Shah"})
    board = board_fixture(%{"name" => "Pricing"}, owner: owner)
    sam = user_fixture("sam@example.com")
    {:ok, sam} = Slipdock.Accounts.update_profile(sam, %{"name" => "Sam Smith"})
    ollie = user_fixture("ollie@example.com")
    {:ok, ollie} = Slipdock.Accounts.update_profile(ollie, %{"name" => "Ollie Reed"})
    share_fixture(board, [sam, ollie], "write")
    %{owner: owner, board: board, sam: sam, ollie: ollie}
  end

  defp voiceprints_on do
    {:ok, _} =
      Settings.update(%{
        "meetings_voiceprints" => true,
        "meetings_voiceprint_url" => "http://voice.example/embed"
      })

    Slipdock.TestConfig.merge(:meetings, voiceprint_req_options: [plug: {Req.Test, __MODULE__}])
  end

  # The endpoint: answers `embed.(file_bytes, segments)` and tells the test
  # what it was sent.
  defp endpoint(embed) do
    test = self()

    Req.Test.stub(__MODULE__, fn conn ->
      conn = Plug.Parsers.call(conn, Plug.Parsers.init(parsers: [:multipart], pass: ["*/*"]))
      bytes = File.read!(conn.params["file"].path)
      segments = conn.params["segments"] && Jason.decode!(conn.params["segments"])
      send(test, {:embedded, bytes, segments})

      case embed.(bytes, segments) do
        {:status, status} -> Plug.Conn.send_resp(conn, status, "nope")
        e -> Req.Test.json(conn, %{"embedding" => e})
      end
    end)
  end

  defp recording(bytes \\ "SAM SPEAKING") do
    path = Path.join(System.tmp_dir!(), "vp-#{System.unique_integer([:positive])}.wav")
    File.write!(path, bytes)
    on_exit(fn -> File.rm(path) end)
    {:recording, path, "me.wav"}
  end

  defp consent, do: [consent: Voiceprints.wording_version()]

  # A recorded meeting: Sam speaks 0–4s, Ollie 4–9s, as voices A and B.
  defp audio_capture(ctx) do
    path = Path.join(System.tmp_dir!(), "m-#{System.unique_integer([:positive])}.wav")
    File.write!(path, "MEETING AUDIO")
    on_exit(fn -> File.rm(path) end)

    {:ok, c} =
      Meetings.create_capture(
        ctx.board,
        ctx.owner,
        %{title: "Call", fingerprint: Meetings.fingerprint(audio: path)},
        audio: %{path: path, filename: "call.wav"},
        utterances: [
          %{speaker: "Voice A", text: "First words.", start_ms: 0, end_ms: 4000},
          %{speaker: "Voice B", text: "Second words.", start_ms: 4000, end_ms: 9000}
        ]
      )

    {:ok, _} = Speakers.diarise(c)
    c
  end

  defp voice(capture, label), do: Repo.get_by!(Voice, capture_id: capture.id, label: label)

  # Who each stretch of the meeting sounds like.
  defp meeting_embed(_bytes, [[start, _] | _]) when start < 4, do: @sam
  defp meeting_embed(_bytes, _), do: @ollie

  describe "while off" do
    test "nothing can be enrolled and nothing is sent", ctx do
      assert Voiceprints.enabled?() == false
      assert Voiceprints.enrol(ctx.sam, recording(), consent()) == {:error, :off}
      assert Repo.aggregate(Voiceprint, :count) == 0
      refute_received {:embedded, _, _}
    end

    test "the switch alone isn't enough: it needs an endpoint" do
      assert {:error, cs} = Settings.update(%{"meetings_voiceprints" => true})
      assert "is needed to turn voiceprints on" in errors_on(cs).meetings_voiceprint_url
    end

    test "with meeting mode off, voiceprints are off whatever the switch says" do
      voiceprints_on()
      assert Voiceprints.enabled?()
      {:ok, _} = Settings.update(%{"meetings_enabled" => false})
      refute Voiceprints.enabled?()
    end

    test "an existing voiceprint isn't used once they are switched off", ctx do
      voiceprints_on()
      endpoint(&meeting_embed/2)
      c = audio_capture(ctx)
      {:ok, _} = Voiceprints.enrol(ctx.sam, recording(), consent())
      flush()

      {:ok, _} = Settings.update(%{"meetings_voiceprints" => false})

      assert Voiceprints.evidence(c, [voice(c, "Voice A")], [%{user_id: ctx.sam.id, name: "Sam"}]) ==
               []

      refute_received {:embedded, _, _}
    end
  end

  describe "enrolling" do
    setup do
      voiceprints_on()
      :ok
    end

    test "from their own recording: the embedding and the consent are kept, the audio isn't",
         ctx do
      uploads = Slipdock.TestConfig.own_uploads_dir()
      endpoint(fn "SAM SPEAKING", nil -> @sam end)

      assert {:ok, print} = Voiceprints.enrol(ctx.sam, recording(), consent())
      assert_received {:embedded, "SAM SPEAKING", nil}
      assert print.embedding == @sam and print.source == "recording"
      assert print.user_id == ctx.sam.id
      assert print.consent_version == Voiceprints.wording_version()
      assert not File.exists?(uploads) or File.ls!(uploads) == []

      assert [%VoiceprintConsent{event: "given", wording: wording, wording_version: v}] =
               Voiceprints.consents(ctx.sam)

      assert wording == Voiceprints.wording() and v == Voiceprints.wording_version()
    end

    test "without consent, or with an old wording's version, nothing is sent or kept", ctx do
      endpoint(fn _, _ -> @sam end)

      assert Voiceprints.enrol(ctx.sam, recording(), []) == {:error, :consent}
      assert Voiceprints.enrol(ctx.sam, recording(), consent: "2020-01-01") == {:error, :consent}
      refute_received {:embedded, _, _}
      assert Repo.aggregate(Voiceprint, :count) == 0
      assert Repo.aggregate(VoiceprintConsent, :count) == 0
    end

    test "enrolling again replaces the voiceprint, and both consents are on record", ctx do
      endpoint(fn
        "FIRST", _ -> @sam
        "SECOND", _ -> @ollie
      end)

      {:ok, _} = Voiceprints.enrol(ctx.sam, recording("FIRST"), consent())
      {:ok, _} = Voiceprints.enrol(ctx.sam, recording("SECOND"), consent())
      assert [%{embedding: embedding}] = Repo.all(Voiceprint)
      assert embedding == @ollie
      assert Enum.map(Voiceprints.consents(ctx.sam), & &1.event) == ~w(given given)
    end

    test "an endpoint that fails or answers nonsense stores nothing", ctx do
      endpoint(fn
        "DOWN", _ -> {:status, 500}
        _, _ -> ["not", "numbers"]
      end)

      assert {:error, "the voiceprint endpoint said 500"} =
               Voiceprints.enrol(ctx.sam, recording("DOWN"), consent())

      assert {:error, "the voiceprint endpoint answered something that isn't an embedding"} =
               Voiceprints.enrol(ctx.sam, recording("ODD"), consent())

      assert Repo.aggregate(Voiceprint, :count) == 0
      assert Voiceprints.consents(ctx.sam) == []
    end

    test "a recording that isn't there is refused", ctx do
      assert {:error, "send a recording of your voice"} =
               Voiceprints.enrol(ctx.sam, {:recording, "/nonexistent.wav", "x.wav"}, consent())
    end
  end

  describe "from a meeting where their voice was confirmed" do
    setup ctx do
      voiceprints_on()
      endpoint(&meeting_embed/2)
      c = audio_capture(ctx)
      {:ok, _} = Speakers.reassign(voice(c, "Voice A"), %{"user_id" => ctx.sam.id}, ctx.owner)
      flush()
      %{capture: c}
    end

    test "is offered to them, and enrols from their own lines only", ctx do
      assert [%{capture: %{id: id}, voice: %{label: "Voice A"}}] = Voiceprints.offers(ctx.sam)
      assert id == ctx.capture.id

      assert {:ok, print} = Voiceprints.enrol(ctx.sam, {:capture, ctx.capture.id}, consent())
      assert_received {:embedded, "MEETING AUDIO", [[+0.0, 4.0]]}
      assert print.source == "meeting" and print.source_capture_id == ctx.capture.id
      assert print.embedding == @sam
      assert Voiceprints.offers(ctx.sam) == []
    end

    test "is never offered to, or usable by, anybody else", ctx do
      assert Voiceprints.offers(ctx.ollie) == []
      assert Voiceprints.offers(ctx.owner) == []

      for who <- [ctx.ollie, ctx.owner] do
        assert {:error, "that meeting has no confirmed voice of yours to enrol from"} =
                 Voiceprints.enrol(who, {:capture, ctx.capture.id}, consent())
      end

      assert Repo.aggregate(Voiceprint, :count) == 0
    end

    test "a voice only guessed to be them (not confirmed) isn't offered", ctx do
      voice(ctx.capture, "Voice B")
      |> Ecto.Changeset.change(user_id: ctx.ollie.id, confidence: "sure")
      |> Repo.update!()

      assert Voiceprints.offers(ctx.ollie) == []
    end

    test "once the recording is gone, there is nothing to offer", ctx do
      ctx.capture |> Ecto.Changeset.change(audio_key: nil) |> Repo.update!()
      assert Voiceprints.offers(ctx.sam) == []

      assert {:error, _} = Voiceprints.enrol(ctx.sam, {:capture, ctx.capture.id}, consent())
    end

    test "nor once they can no longer read the board", ctx do
      Repo.delete_all(from(g in Slipdock.Access.Grant, where: g.user_id == ^ctx.sam.id))

      refute Slipdock.Access.can_read?(Slipdock.Access.board_permission(ctx.sam, ctx.board))
      assert Voiceprints.offers(ctx.sam) == []
      assert {:error, _} = Voiceprints.enrol(ctx.sam, {:capture, ctx.capture.id}, consent())
    end

    test "a capture id that is junk is refused", ctx do
      assert {:error, _} = Voiceprints.enrol(ctx.sam, {:capture, "abc"}, consent())
    end
  end

  describe "as evidence of who spoke" do
    setup ctx do
      voiceprints_on()

      endpoint(fn
        "SAM", nil -> @sam
        "OLLIE", nil -> @ollie
        bytes, segs -> meeting_embed(bytes, segs)
      end)

      {:ok, _} = Voiceprints.enrol(ctx.sam, recording("SAM"), consent())
      :ok
    end

    test "a voice that sounds like an enrolled person is attributed to them, with the score",
         ctx do
      c = audio_capture(ctx)
      {:ok, _} = Speakers.attribute(c)

      a = voice(c, "Voice A")
      assert a.user_id == ctx.sam.id and a.confidence == "sure"

      assert [%{"kind" => "voiceprint", "strength" => "strong", "score" => 1.0, "detail" => d}] =
               a.evidence

      assert d =~ "sounds like Sam Smith's voiceprint (similarity 1.00)"
      # Ollie never enrolled: Voice B is left to the other evidence.
      assert voice(c, "Voice B").user_id == nil
    end

    test "after they delete it, later captures stop using it", ctx do
      assert :ok = Voiceprints.delete(ctx.sam)
      c = audio_capture(ctx)
      flush()
      {:ok, _} = Speakers.attribute(c)

      assert voice(c, "Voice A").user_id == nil
      assert voice(c, "Voice A").evidence == []
      refute_received {:embedded, _, _}
    end

    test "a distant voice says nothing; an endpoint failure is not a failed capture", ctx do
      c = audio_capture(ctx)
      far = [{voice(c, "Voice B"), [%{user_id: ctx.sam.id, name: "Sam Smith"}]}]

      for {v, people} <- far, do: assert(Voiceprints.evidence(c, [v], people) == [])

      endpoint(fn _, _ -> {:status, 503} end)
      assert {:ok, _} = Speakers.attribute(c)
      assert voice(c, "Voice A").evidence == []
    end

    test "a capture without a recording isn't compared", ctx do
      c = capture_fixture(ctx.board, ctx.owner)
      flush()
      {:ok, _} = Speakers.diarise(c)
      {:ok, _} = Speakers.attribute(c)
      refute_received {:embedded, _, _}
    end
  end

  describe "deleting" do
    setup do
      voiceprints_on()
      endpoint(fn _, _ -> @sam end)
      :ok
    end

    test "removes the embedding and records the withdrawal", ctx do
      {:ok, _} = Voiceprints.enrol(ctx.sam, recording(), consent())
      assert :ok = Voiceprints.delete(ctx.sam)
      assert Voiceprints.get(ctx.sam) == nil
      assert Repo.aggregate(Voiceprint, :count) == 0
      assert Enum.map(Voiceprints.consents(ctx.sam), & &1.event) == ~w(given withdrawn)
    end

    test "only ever their own", ctx do
      {:ok, _} = Voiceprints.enrol(ctx.sam, recording(), consent())
      assert Voiceprints.delete(ctx.ollie) == {:error, :none}
      assert Voiceprints.get(ctx.sam)
      assert Voiceprints.consents(ctx.ollie) == []
    end

    test "goes with the account", ctx do
      {:ok, _} = Voiceprints.enrol(ctx.sam, recording(), consent())
      Repo.delete!(ctx.sam)
      assert Repo.aggregate(Voiceprint, :count) == 0
      assert Repo.aggregate(VoiceprintConsent, :count) == 0
    end
  end

  describe "the export" do
    setup do
      voiceprints_on()
      endpoint(fn _, _ -> @sam end)
      :ok
    end

    test "has their voiceprint and consent record, and nobody else's", ctx do
      {:ok, _} = Voiceprints.enrol(ctx.sam, recording(), consent())
      {_, zip} = Slipdock.AccountExport.zip(ctx.sam)
      {:ok, files} = :zip.unzip(zip, [:memory])
      files = Map.new(files, fn {name, bytes} -> {to_string(name), bytes} end)

      data = Jason.decode!(files["voiceprint.json"])
      assert data["voiceprint"]["embedding"] == @sam
      assert [%{"event" => "given", "wording" => w}] = data["consent"]
      assert w == Voiceprints.wording()

      {_, other} = Slipdock.AccountExport.zip(ctx.ollie)
      {:ok, other} = :zip.unzip(other, [:memory])
      refute Enum.any?(other, fn {name, _} -> to_string(name) == "voiceprint.json" end)
    end

    test "keeps the consent record after a deletion", ctx do
      {:ok, _} = Voiceprints.enrol(ctx.sam, recording(), consent())
      :ok = Voiceprints.delete(ctx.sam)

      assert %{voiceprint: nil, consent: [%{event: "given"}, %{event: "withdrawn"}]} =
               Voiceprints.export(ctx.sam)
    end
  end

  test "cosine similarity" do
    assert Voiceprints.cosine([1.0, 0.0], [1.0, 0.0]) == 1.0
    assert Voiceprints.cosine([1.0, 0.0], [0.0, 1.0]) == 0.0
    assert Voiceprints.cosine([1.0], [1.0, 0.0]) == 0.0
    assert Voiceprints.cosine([0.0, 0.0], [1.0, 0.0]) == 0.0
  end

  defp flush do
    receive do
      {:embedded, _, _} -> flush()
    after
      0 -> :ok
    end
  end
end
