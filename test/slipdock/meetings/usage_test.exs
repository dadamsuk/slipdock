defmodule Slipdock.Meetings.UsageTest do
  @moduledoc """
  The usage ledger and the limits (#544): each limit refuses before anything
  is stored or sent to a provider, with a 402-shaped refusal naming it; a
  transcript sent with the recording uses no transcription; work on a
  person's own key does not count; and the totals are the ledger's sums.
  """
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures
  import Slipdock.MeetingsFixtures

  alias Slipdock.{AI, Repo, Settings}
  alias Slipdock.Meetings.{Audio, Capture, Ingest, Usage, UsageEntry}

  setup do
    owner = user_fixture("owner@example.com")
    board = board_fixture(%{"name" => "Pricing"}, owner: owner)
    %{owner: owner, board: board}
  end

  # A real WAV header: 16 kHz mono 16-bit, `seconds` of silence.
  defp wav(seconds) do
    rate = 16_000
    data = seconds * rate * 2

    header =
      <<"RIFF", 36 + data::little-32, "WAVE", "fmt ", 16::little-32, 1::little-16, 1::little-16,
        rate::little-32, rate * 2::little-32, 2::little-16, 16::little-16, "data",
        data::little-32>>

    path = Path.join(System.tmp_dir!(), "u-#{System.unique_integer([:positive])}.wav")
    File.write!(path, [header, :binary.copy(<<0>>, min(data, 64_000))])
    on_exit(fn -> File.rm(path) end)
    path
  end

  defp audio(path), do: %{path: path, filename: Path.basename(path), content_type: "audio/wav"}

  test "a WAV's length comes from its header; anything else is estimated from its size" do
    assert Audio.duration_ms(wav(90)) == 90_000
    assert Audio.estimate_ms(16_000 * 60) == 60_000
  end

  describe "captures from transcripts" do
    test "the month's allowance refuses the next one, naming the limit", %{
      owner: owner,
      board: board
    } do
      {:ok, _} =
        Settings.update(%{
          "meetings_transcript_captures" => 1,
          "meetings_transcript_captures_enabled" => true
        })

      {:ok, _} = Ingest.ingest(board, owner, %{transcript: "Sam: one"})

      assert {:error, {:limit, "meeting_limit_reached", message}} =
               Ingest.ingest(board, owner, %{transcript: "Sam: two"})

      assert message =~ "1 meetings as transcripts this month, the most this server allows (1)"
      assert Repo.aggregate(Capture, :count) == 1

      {:ok, _} = Settings.update(%{"meetings_transcript_captures_enabled" => false})
      assert {:ok, _} = Ingest.ingest(board, owner, %{transcript: "Sam: three"})
    end
  end

  describe "transcription minutes" do
    setup do
      {:ok, _} =
        Settings.update(%{
          "meetings_transcription_minutes" => 1,
          "meetings_transcription_minutes_enabled" => true
        })

      :ok
    end

    test "a recording that would pass them is refused before anything is stored or sent", %{
      owner: owner,
      board: board
    } do
      Req.Test.stub(Slipdock.AI, fn conn ->
        send(self(), :provider_called)
        Req.Test.json(conn, %{})
      end)

      assert {:error, {:limit, "meeting_limit_reached", message}} =
               Ingest.ingest(board, owner, %{audio: audio(wav(90))})

      assert message =~ "past this month's 1 transcription minutes"
      assert Repo.aggregate(Capture, :count) == 0
      assert Repo.aggregate(UsageEntry, :count) == 0
      refute_received :provider_called
    end

    test "a transcript sent with the recording uses none", %{owner: owner, board: board} do
      assert {:ok, capture} =
               Ingest.ingest(board, owner, %{audio: audio(wav(90)), transcript: "Sam: hello"})

      assert capture.audio_duration_ms == 90_000
      assert Usage.month(owner).transcription_seconds == 0.0
    end

    test "on the person's own key they don't count", %{owner: owner, board: board} do
      :ok = AI.Keys.put_settings(owner, %{api_key: "sk-or-their-own"})
      on_exit(fn -> AI.Keys.put_settings(owner, %{api_key: ""}) end)
      assert {:ok, _} = Ingest.ingest(board, owner, %{audio: audio(wav(90))})
    end
  end

  test "stored audio has its own limit, and is on the ledger", %{owner: owner, board: board} do
    {:ok, _} =
      Settings.update(%{
        "meetings_audio_storage_mb" => 0,
        "meetings_audio_storage_mb_enabled" => true
      })

    assert {:error, {:limit, _, message}} =
             Ingest.ingest(board, owner, %{audio: audio(wav(5)), transcript: "Sam: hi"})

    assert message =~ "past the 0 MB this server allows each person"

    {:ok, _} = Settings.update(%{"meetings_audio_storage_mb" => 10})
    {:ok, capture} = Ingest.ingest(board, owner, %{audio: audio(wav(5)), transcript: "Sam: hi"})
    assert [%UsageEntry{kind: "storage", bytes: bytes}] = Usage.for_capture(capture)
    assert bytes == capture.audio_size
    assert Usage.month(owner).audio_bytes == capture.audio_size
  end

  test "the longest meeting and the largest file are the admin's", %{owner: owner, board: board} do
    {:ok, _} = Settings.update(%{"meetings_longest_minutes" => 1})

    assert {:error, {:invalid, message}} =
             Ingest.ingest(board, owner, %{audio: audio(wav(90)), transcript: "Sam: hi"})

    assert message =~
             "the recording runs about 1 minutes; the longest this server reads is 1 minutes"

    {:ok, _} = Settings.update(%{"meetings_longest_minutes" => 240, "meetings_max_file_mb" => 1})
    big = Path.join(System.tmp_dir!(), "big-#{System.unique_integer([:positive])}.mp3")
    File.write!(big, :binary.copy("x", 1_100_000))
    on_exit(fn -> File.rm(big) end)

    assert {:error, {:invalid, message}} =
             Ingest.ingest(board, owner, %{audio: %{path: big, filename: "big.mp3"}})

    assert message =~ "the most this server takes is 1.0 MB"
  end

  test "the month's totals are the sums of the ledger, own keys apart", %{
    owner: owner,
    board: board
  } do
    capture = capture_fixture(board, owner)
    Usage.record(capture, %{kind: :transcription, seconds: 120.5, cost: 0.02})
    Usage.record(capture, %{kind: :transcription, seconds: 60.0, own_key: true, cost: 0.01})
    Usage.record(capture, %{kind: :reading, tokens_in: 1000, tokens_out: 200, cost: "0.003"})
    Usage.record(capture, %{kind: :reading, tokens_in: 10, tokens_out: 5, cost: 0.001})

    month = Usage.month(owner)
    entries = Usage.for_capture(capture)
    shared = Enum.reject(entries, & &1.own_key)

    assert month.transcription_seconds == 120.5
    assert month.own_transcription_seconds == 60.0
    assert month.tokens_in == Enum.sum(Enum.map(entries, &(&1.tokens_in || 0)))
    assert month.tokens_out == 205
    assert_in_delta month.cost, Enum.sum(Enum.map(shared, &(&1.cost || 0))), 0.0000001
    assert month.transcript_captures == 1

    server = Usage.server_month()
    assert server.transcription_minutes == 2
    assert server.tokens == 1215
    assert [%{email: email, tokens: 1215}] = server.heaviest
    assert email == owner.email
  end

  test "last month's lines are not this month's", %{owner: owner, board: board} do
    capture = capture_fixture(board, owner)

    Repo.insert!(%UsageEntry{
      user_id: owner.id,
      capture_id: capture.id,
      kind: "transcription",
      seconds: 999.0,
      month: ~D[2020-01-01],
      inserted_at: DateTime.utc_now()
    })

    assert Usage.month(owner).transcription_seconds == 0.0
  end

  test "the allowance says what is left", %{owner: owner, board: board} do
    {:ok, _} =
      Settings.update(%{
        "meetings_transcript_captures" => 5,
        "meetings_transcript_captures_enabled" => true,
        "meetings_transcription_minutes_enabled" => false
      })

    capture_fixture(board, owner)
    allowance = Usage.allowance(owner)
    assert allowance.transcript_captures == %{used: 1, limit: 5, left: 4}
    assert allowance.transcription_minutes.limit == nil
  end
end
