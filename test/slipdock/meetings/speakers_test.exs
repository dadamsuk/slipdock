defmodule Slipdock.Meetings.SpeakersTest do
  @moduledoc """
  Who spoke (#546): voices from the transcript's labels or a diarisation
  endpoint (crosstalk marked unsure), each attributed with its evidence —
  the label, being addressed then answering, an introduction, elimination —
  over-split voices merged, and a person's correction re-deriving exactly
  the findings that depended on that voice.
  """
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures
  import Slipdock.MeetingsFixtures

  alias Slipdock.{Repo, Settings}
  alias Slipdock.Meetings.{Finding, Question, Speakers, Utterance, Voice}

  setup do
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

  defp capture(ctx, lines, attrs \\ %{}) do
    attrs = Map.put(attrs, :transcript, "#{System.unique_integer()}")
    capture_fixture(ctx.board, ctx.owner, attrs, utterances: lines)
  end

  defp run(capture) do
    {:ok, _} = Speakers.diarise(capture)
    {:ok, _} = Speakers.attribute(capture)
    voices(capture)
  end

  defp voices(capture),
    do:
      Repo.all(from(v in Voice, where: v.capture_id == ^capture.id, order_by: v.id))
      |> Map.new(&{&1.label, &1})

  test "“Good question, Sam.” then a voice answering: that voice is Sam, with the line as evidence",
       ctx do
    c =
      capture(ctx, [
        %{speaker: "Speaker 1", text: "Good question, Sam."},
        %{speaker: "Speaker 3", text: "I think we ship on Friday."}
      ])

    voices = run(c)
    v = voices["Speaker 3"]
    assert v.user_id == ctx.sam.id and v.name == "Sam Smith"
    assert v.confidence == "confirm"
    assert [%{"kind" => "addressed", "line" => "L2", "detail" => detail}] = v.evidence
    assert detail =~ "“Good question, Sam.” (L1), then this voice answered (L2)"
    assert voices["Speaker 1"].user_id == nil
  end

  test "an introduction says who; a name in the label says it strongly", ctx do
    voices =
      run(
        capture(ctx, [
          %{speaker: "Speaker 1", text: "Hi all, I'm Ollie, sorry I'm late."},
          %{speaker: "Priya Shah", text: "Welcome."}
        ])
      )

    assert %{user_id: ollie_id, confidence: "sure"} = voices["Speaker 1"]
    assert ollie_id == ctx.ollie.id

    assert %{
             user_id: owner_id,
             confidence: "sure",
             evidence: [%{"kind" => "label", "strength" => "strong"}]
           } = voices["Priya Shah"]

    assert owner_id == ctx.owner.id
  end

  test "the one voice left is the one attendee left", ctx do
    attendees = [
      %{"name" => "Priya Shah", "user_id" => ctx.owner.id},
      %{"name" => "Sam Smith", "user_id" => ctx.sam.id}
    ]

    voices =
      run(
        capture(
          ctx,
          [%{speaker: "Priya", text: "Shall we?"}, %{speaker: "Speaker 2", text: "Let's."}],
          %{attendees: attendees}
        )
      )

    assert voices["Priya"].user_id == ctx.owner.id

    assert %{user_id: sam_id, confidence: "confirm", evidence: [%{"kind" => "elimination"}]} =
             voices["Speaker 2"]

    assert sam_id == ctx.sam.id
  end

  test "dialogue inference can be switched off", ctx do
    {:ok, _} = Settings.update(%{"meetings_dialogue_inference" => false})

    voices =
      run(
        capture(ctx, [
          %{speaker: "Speaker 1", text: "Good question, Sam."},
          %{speaker: "Speaker 3", text: "Yes."}
        ])
      )

    assert voices["Speaker 3"].user_id == nil
    assert voices["Speaker 3"].confidence == "unknown"
  end

  test "two voices that are the same person are merged, and the merge shows", ctx do
    c = capture(ctx, [%{speaker: "Sam Smith", text: "One."}, %{speaker: "Sam", text: "Two."}])
    voices = run(c)

    assert voices["Sam"].merged_into_id == voices["Sam Smith"].id

    assert Enum.any?(
             voices["Sam Smith"].evidence,
             &(&1["kind"] == "merged" and &1["detail"] =~ "Sam merged into this voice")
           )

    assert Repo.all(from(u in Utterance, where: u.capture_id == ^c.id, select: u.voice_id))
           |> Enum.uniq() == [voices["Sam Smith"].id]
  end

  test "a diarisation endpoint's turns become voices, with crosstalk marked unsure", ctx do
    {:ok, _} =
      Settings.update(%{
        "meetings_diarisation" => "endpoint",
        "meetings_diarisation_url" => "http://diarise.example/diarise"
      })

    Slipdock.TestConfig.merge(:meetings, diarisation_req_options: [plug: {Req.Test, __MODULE__}])

    Req.Test.stub(__MODULE__, fn conn ->
      Req.Test.json(conn, %{
        "segments" => [
          %{"start" => 0.0, "end" => 4.0, "speaker" => "A"},
          %{"start" => 4.0, "end" => 9.0, "speaker" => "B"},
          %{"start" => 6.0, "end" => 9.0, "speaker" => "A"}
        ]
      })
    end)

    path = Path.join(System.tmp_dir!(), "d-#{System.unique_integer([:positive])}.wav")
    File.write!(path, "RIFF....WAVE")
    on_exit(fn -> File.rm(path) end)

    {:ok, c} =
      Slipdock.Meetings.create_capture(
        ctx.board,
        ctx.owner,
        %{title: "Call", fingerprint: Slipdock.Meetings.fingerprint(audio: path)},
        audio: %{path: path, filename: "call.wav"},
        utterances: [
          %{text: "First words.", start_ms: 0, end_ms: 4000},
          %{text: "Talking over each other.", start_ms: 4000, end_ms: 9000}
        ]
      )

    voices = run(c)
    assert Map.keys(voices) |> Enum.sort() == ["Voice A", "Voice B"]
    [l1, l2] = Repo.all(from(u in Utterance, where: u.capture_id == ^c.id, order_by: u.position))
    assert l1.voice_id == voices["Voice A"].id and not l1.voice_unsure
    assert l2.voice_id == voices["Voice B"].id and l2.voice_unsure
  end

  describe "a person's correction" do
    setup ctx do
      c =
        capture(ctx, [
          %{speaker: "Priya Shah", text: "Can someone take the pricing page?"},
          %{speaker: "Speaker 3", text: "Good question, Sam."},
          %{speaker: "Speaker 2", text: "Yes, that's mine."},
          %{speaker: "Priya Shah", text: "And the launch email is yours, Ollie."}
        ])

      run(c)
      voices = voices(c)
      assert voices["Speaker 2"].user_id == ctx.sam.id

      mine =
        action_finding("Sam", %{
          "title" => "Pricing page",
          "evidence" => [%{"line" => "L3", "quote" => "Yes, that's mine."}]
        })

      other =
        action_finding("Ollie", %{
          "title" => "Launch email",
          "evidence" => [%{"line" => "L4", "quote" => "the launch email is yours, Ollie"}]
        })

      c =
        c
        |> Ecto.Changeset.change(
          readings: %{"1" => [mine, other]},
          context: %{"candidates" => [], "decisions" => []}
        )
        |> Repo.update!()

      {:ok, _} = Slipdock.Meetings.verify(c)

      [f_mine, f_other] =
        Repo.all(from(f in Finding, where: f.capture_id == ^c.id, order_by: f.position))

      %{capture: c, voices: voices, mine: f_mine, other: f_other}
    end

    test "changes the owner of findings that depended on that voice, and only those", ctx do
      assert ctx.mine.effect["owner_voice_id"] == ctx.voices["Speaker 2"].id
      assert ctx.mine.effect["assignee_id"] == ctx.sam.id
      refute Map.has_key?(ctx.other.effect, "owner_voice_id")

      {:ok, voice} =
        Speakers.reassign(ctx.voices["Speaker 2"], %{"user_id" => ctx.ollie.id}, ctx.owner)

      assert voice.confidence == "confirmed" and voice.confirmed_by_id == ctx.owner.id

      assert Repo.reload!(ctx.mine).effect["assignee_id"] == ctx.ollie.id
      assert Repo.reload!(ctx.mine).effect["assignee"] == "Ollie Reed"
      assert Repo.reload!(ctx.other).effect == ctx.other.effect
    end

    test "to somebody with no account, by name", ctx do
      {:ok, _} =
        Speakers.reassign(ctx.voices["Speaker 2"], %{"name" => "Dana (contractor)"}, ctx.owner)

      effect = Repo.reload!(ctx.mine).effect
      assert effect["assignee"] == "Dana (contractor)"
      assert effect["assignee_id"] == nil

      assert {:error, "say who it is" <> _} =
               Speakers.reassign(ctx.voices["Speaker 2"], %{"name" => " "}, ctx.owner)
    end
  end

  test "crosstalk nothing depends on raises no question; crosstalk a finding depends on does",
       ctx do
    c =
      capture(ctx, [
        %{speaker: "Speaker 1", text: "Background chatter here."},
        %{speaker: "Speaker 2", text: "We decide to ship Friday."}
      ])

    run(c)
    Repo.update_all(from(u in Utterance, where: u.capture_id == ^c.id), set: [voice_unsure: true])

    decision = %{
      "kind" => "decision",
      "title" => "Ship Friday",
      "decided_by" => nil,
      "evidence" => [%{"line" => "L2", "quote" => "We decide to ship Friday."}]
    }

    c =
      c
      |> Ecto.Changeset.change(
        readings: %{"1" => [decision]},
        context: %{"candidates" => [], "decisions" => []}
      )
      |> Repo.update!()

    {:ok, _} = Slipdock.Meetings.verify(c)

    questions = Repo.all(from(q in Question, where: q.capture_id == ^c.id))
    assert [%Question{kind: "who_said_it", context: %{"line" => "L2"}}] = questions
    assert Enum.map(Speakers.unsure_lines_that_matter(c), & &1.line_id) == ["L2"]
  end

  test "person_label? tells a person's name from a placeholder for a voice" do
    for name <- ["Priya Nair", "Ryan", "José", "Dr. Okafor"],
        do: assert(Speakers.person_label?(name))

    for label <- [
          "Speaker 2",
          "speaker_00",
          "SPEAKER_01",
          "Unknown-3",
          "Unknown",
          "Voice 4",
          "S1",
          "spk 2",
          "Participant 7",
          "Guest",
          "",
          "  ",
          "42",
          nil
        ],
        do: refute(Speakers.person_label?(label), inspect(label))
  end
end
