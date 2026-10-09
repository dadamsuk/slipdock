defmodule Slipdock.Meetings.CapturesTest do
  @moduledoc """
  Captures as data (#531): the state machine, the fingerprint that finds a
  meeting sent twice (G10), the recording stored and counted against file
  storage, everything going with a capture, a board or an account, and the
  captures in both exports.
  """
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures
  import Slipdock.MeetingsFixtures

  alias Slipdock.{Accounts, Boards, Meetings, Quota, Repo, Settings}
  alias Slipdock.Meetings.{Capture, Event, Evidence, Finding, Question, Utterance}

  setup do
    owner = user_fixture("owner@example.com")
    board = board_fixture(%{"name" => "Pricing", "code" => "PL"}, owner: owner)
    %{owner: owner, board: board}
  end

  defp audio_file(bytes \\ "RIFF....WAVEfmt fake audio") do
    path = Path.join(System.tmp_dir!(), "meeting-#{System.unique_integer([:positive])}.wav")
    File.write!(path, bytes)
    on_exit(fn -> File.rm(path) end)
    path
  end

  describe "creating one" do
    test "keeps the transcript as received and numbers its lines", %{owner: owner, board: board} do
      capture = capture_fixture(board, owner)
      capture = Meetings.load(capture)

      assert capture.state == "receiving"
      assert capture.transcript =~ "Sam: We go with the annual plan at 20% off."
      assert Enum.map(capture.utterances, & &1.line_id) == ~w(L1 L2 L3 L4)
      assert [%{speaker: "Priya", start_ms: 0, end_ms: 4000} | _] = capture.utterances

      assert [%Event{kind: "received", message: "Received a transcript for “Pricing sync”."}] =
               capture.events
    end

    test "stamps the board as having had a capture", %{owner: owner, board: board} do
      refute board.meetings_used_at
      capture_fixture(board, owner)
      assert Repo.get!(Slipdock.Boards.Board, board.id).meetings_used_at
    end

    test "needs a title and a fingerprint", %{owner: owner, board: board} do
      assert {:error, cs} = Meetings.create_capture(board, owner, %{title: " "})
      assert %{title: [_], fingerprint: [_]} = errors_on(cs)
      assert Repo.aggregate(Capture, :count) == 0
    end
  end

  describe "the fingerprint (G10)" do
    test "the same transcript twice finds the first capture", %{owner: owner, board: board} do
      text = transcript()
      first = capture_fixture(board, owner, %{transcript: text})

      assert {:existing, %Capture{id: id}} =
               Meetings.create_capture(board, owner, %{
                 title: "Again",
                 transcript: text,
                 fingerprint: Meetings.fingerprint(transcript: text)
               })

      assert id == first.id
      assert Repo.aggregate(Capture, :count) == 1
    end

    test "line endings, a byte-order mark and stray spaces are the same meeting" do
      plain = "Priya: Hello\nSam: Hi there"
      messy = "\uFEFFPriya: Hello  \r\n\r\nSam: Hi there\r\n"
      assert Meetings.fingerprint(transcript: plain) == Meetings.fingerprint(transcript: messy)

      refute Meetings.fingerprint(transcript: plain) ==
               Meetings.fingerprint(transcript: "Sam: Hi")
    end

    test "is per board: another board may hold the same meeting", %{owner: owner, board: board} do
      other = board_fixture(%{"name" => "Other"}, owner: owner)
      text = transcript()
      capture_fixture(board, owner, %{transcript: text})
      assert %Capture{} = capture_fixture(other, owner, %{transcript: text})
    end

    test "covers audio, and audio with a transcript is a different meeting from either" do
      path = audio_file()
      audio = Meetings.fingerprint(audio: path)
      both = Meetings.fingerprint(audio: path, transcript: "Sam: Hi")

      assert audio =~ ~r/^a:[0-9a-f]{64}$/
      assert both =~ ~r/^t:[0-9a-f]{64}\+a:[0-9a-f]{64}$/
      assert_raise ArgumentError, fn -> Meetings.fingerprint([]) end
    end
  end

  describe "states" do
    setup %{owner: owner, board: board}, do: %{capture: capture_fixture(board, owner)}

    test "go the way they are drawn, each move on the record", %{capture: capture, owner: owner} do
      {:ok, c} = Meetings.transition(capture, "reading")
      {:ok, c} = Meetings.transition(c, "needs_review")
      {:ok, c} = Meetings.transition(c, "ready", user: owner)
      {:ok, c} = Meetings.transition(c, "needs_review")
      {:ok, c} = Meetings.transition(c, "ready")
      {:ok, c} = Meetings.transition(c, "committed", user: owner)

      assert c.state == "committed"

      kinds =
        Repo.all(from(e in Event, where: e.capture_id == ^c.id, order_by: e.id, select: e.data))

      assert Enum.map(tl(kinds), & &1["to"]) ==
               ~w(reading needs_review ready needs_review ready committed)
    end

    test "a failure keeps its reason, and retry reads again", %{capture: capture} do
      {:ok, c} = Meetings.transition(capture, "reading")
      {:ok, c} = Meetings.transition(c, "failed", reason: "the provider said 503")
      assert c.state_reason == "the provider said 503"

      assert [%{message: "Failed: the provider said 503."}] =
               Repo.all(
                 from(e in Event,
                   where: e.capture_id == ^c.id and e.kind == "state" and e.data["to"] == "failed"
                 )
               )

      {:ok, c} = Meetings.transition(c, "reading")
      assert c.state == "reading"
      assert c.state_reason == nil
    end

    test "refuse every move not drawn", %{capture: capture} do
      for {from, to} <- [
            {"receiving", "committed"},
            {"receiving", "ready"},
            {"reading", "committed"},
            {"needs_review", "committed"},
            {"committed", "ready"},
            {"committed", "committed"},
            {"discarded", "ready"},
            {"failed", "committed"}
          ] do
        c = %{capture | state: from}
        assert {:error, cs} = Meetings.transition(c, to)
        assert %{state: ["cannot go from #{from} to #{to}"]} == errors_on(cs)
      end
    end

    test "a committed or discarded capture is closed, a reading one active", %{capture: capture} do
      assert Capture.active?(%{capture | state: "reading"})
      assert Capture.closed?(%{capture | state: "committed"})
      assert Capture.closed?(%{capture | state: "discarded"})
      refute Capture.closed?(%{capture | state: "ready"})
    end
  end

  describe "the recording" do
    test "is stored with the uploads and counted against the board owner's storage", %{
      owner: owner,
      board: board
    } do
      path = audio_file()
      size = File.stat!(path).size
      before = Quota.used(owner, :storage)

      {:ok, capture} =
        Meetings.create_capture(
          board,
          owner,
          %{title: "Call", fingerprint: Meetings.fingerprint(audio: path)},
          audio: %{path: path, filename: "call.WAV", content_type: "audio/wav"}
        )

      assert capture.audio_key =~ ~r{^captures/[0-9a-f-]+\.wav$}
      assert capture.audio_size == size
      assert File.read!(Meetings.audio_path(capture)) == File.read!(path)
      assert Quota.used(owner, :storage) == before + size
      assert Quota.usage([owner.id])[owner.id].storage == before + size

      # Deleting the capture deletes the file and frees the storage.
      {:ok, _} = Meetings.delete_capture(capture)
      refute File.exists?(Meetings.audio_path(capture))
      assert Quota.used(owner, :storage) == before
    end

    test "is refused before a byte is stored when it would pass the storage limit", %{
      owner: owner,
      board: board
    } do
      {:ok, _} = Settings.update(%{"storage_limit_mb" => 1, "storage_limit_enabled" => true})
      path = audio_file(:binary.copy("x", 1_100_000))

      stored = fn ->
        case File.ls(Path.join(Boards.uploads_dir(), "captures")) do
          {:ok, names} -> length(names)
          {:error, _} -> 0
        end
      end

      files_before = stored.()

      assert {:error, cs} =
               Meetings.create_capture(
                 board,
                 owner,
                 %{title: "Long call", fingerprint: Meetings.fingerprint(audio: path)},
                 audio: %{path: path, filename: "long.mp3"}
               )

      assert Quota.limit_kind(cs) == :storage
      assert Repo.aggregate(Capture, :count) == 0
      assert stored.() == files_before
    end
  end

  describe "deleting" do
    test "a capture takes its lines, findings, evidence, questions and record", %{
      owner: owner,
      board: board
    } do
      capture = capture_fixture(board, owner)
      finding = finding_fixture(capture, %{quote: "We go with the annual plan at 20% off."})
      question_fixture(capture, %{finding_id: finding.id})

      {:ok, _} = Meetings.delete_capture(capture)

      for schema <- [Capture, Utterance, Finding, Evidence, Question, Event] do
        assert Repo.aggregate(schema, :count) == 0, inspect(schema)
      end
    end

    test "a board takes its captures and their recordings", %{owner: owner, board: board} do
      path = audio_file()

      {:ok, capture} =
        Meetings.create_capture(
          board,
          owner,
          %{title: "Call", fingerprint: Meetings.fingerprint(audio: path)},
          audio: %{path: path, filename: "call.m4a"}
        )

      {:ok, _} = Boards.delete_board(board)
      assert Repo.aggregate(Capture, :count) == 0
      refute File.exists?(Meetings.audio_path(capture))
    end

    test "an account takes the captures it sent, recordings and all, on anybody's board", %{
      board: board
    } do
      guest = user_fixture("guest@example.com")
      share_fixture(board, [guest], "write")
      path = audio_file()

      {:ok, capture} =
        Meetings.create_capture(
          board,
          guest,
          %{title: "Guest call", fingerprint: Meetings.fingerprint(audio: path)},
          audio: %{path: path, filename: "call.ogg"}
        )

      {:ok, _} = Accounts.delete_user(guest)
      assert Repo.get(Capture, capture.id) == nil
      refute File.exists?(Meetings.audio_path(capture))
      # The board itself is the owner's, and stays.
      assert Repo.get(Slipdock.Boards.Board, board.id)
    end
  end

  describe "exports" do
    setup %{owner: owner, board: board} do
      capture = capture_fixture(board, owner)

      finding =
        finding_fixture(capture, %{
          quote: "We go with the annual plan at 20% off.",
          effect: %{"type" => "decision_entry", "page" => "Decisions / Pricing"}
        })

      question_fixture(capture, %{
        finding_id: finding.id,
        status: "answered",
        answer: %{"value" => "u:#{owner.id}", "label" => owner.email},
        answered_by_id: owner.id,
        answered_at: ~U[2026-10-08 09:00:00Z],
        via: "web",
        context: %{"replayed" => "00:04–00:09"}
      })

      %{capture: capture}
    end

    test "the account export has each capture sent, with findings and resolutions", %{
      owner: owner
    } do
      {_name, zip} = Slipdock.AccountExport.zip(owner)
      {:ok, files} = :zip.unzip(zip, [:memory])
      files = Map.new(files, fn {name, body} -> {to_string(name), body} end)

      [{name, json}] =
        Enum.filter(files, fn {name, _} -> String.starts_with?(name, "captures/") end)

      assert name =~ ~r{^captures/pl-\d+\.json$}
      capture = Jason.decode!(json)

      assert capture["title"] == "Pricing sync"
      assert capture["sent_by"] == owner.email
      assert capture["board"] == "Pricing"
      assert [%{"id" => "L1", "speaker" => "Priya"} | _] = capture["lines"]

      assert [%{"kind" => "decision", "evidence" => [%{"quote" => quote}]}] = capture["findings"]
      assert quote == "We go with the annual plan at 20% off."

      assert [
               %{
                 "status" => "answered",
                 "answered_by" => answered_by,
                 "via" => "web",
                 "context" => %{"replayed" => "00:04–00:09"}
               }
             ] = capture["questions"]

      assert answered_by == owner.email
      assert [%{"kind" => "received", "by" => by}] = capture["record"]
      assert by == owner.email
    end

    test "the recording goes in only when asked for", %{owner: owner, board: board} do
      path = audio_file("the actual audio bytes")

      {:ok, _} =
        Meetings.create_capture(
          board,
          owner,
          %{title: "Call", fingerprint: Meetings.fingerprint(audio: path)},
          audio: %{path: path, filename: "call.mp3"}
        )

      names = fn opts ->
        {_, zip} = Slipdock.AccountExport.zip(owner, opts)
        {:ok, files} = :zip.unzip(zip, [:memory])
        Map.new(files, fn {name, body} -> {to_string(name), body} end)
      end

      without = names.([])
      refute Enum.any?(Map.keys(without), &String.ends_with?(&1, ".mp3"))

      with_audio = names.(audio: true)
      [{_, bytes}] = Enum.filter(with_audio, fn {name, _} -> String.ends_with?(name, ".mp3") end)
      assert bytes == "the actual audio bytes"
    end

    test "the board export carries the board's captures, and still imports", %{owner: owner} do
      document = Slipdock.Portable.export(owner)
      [tree] = document.boards
      assert [%{title: "Pricing sync", board: "b1", findings: [_]}] = tree.captures

      # Through JSON and back in: the captures are a record, not imported.
      decoded = document |> Jason.encode!() |> Jason.decode!()
      importer = user_fixture("importer@example.com")
      assert {:ok, _} = Slipdock.Portable.import(importer, decoded)

      assert Repo.aggregate(
               from(c in Capture, join: b in assoc(c, :board), where: b.owner_id == ^importer.id),
               :count
             ) == 0
    end
  end
end
