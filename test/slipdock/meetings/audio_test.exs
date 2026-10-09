defmodule Slipdock.Meetings.AudioTest do
  @moduledoc """
  Recordings (#545): transcribed through an OpenAI-compatible endpoint, long
  ones in overlapping stretches stitched without a word lost or doubled;
  provider errors failing the capture in the provider's words, and retry; a
  supplied transcript lined up without a byte of it changed; and recordings
  deleted when their keeping runs out, freeing the storage.
  """
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures
  import Slipdock.MeetingsFixtures

  alias Slipdock.{Meetings, Quota, Repo, Settings}
  alias Slipdock.Meetings.{Audio, Capture, Ingest, Pipeline, Transcriber, Usage, Utterance}

  setup do
    owner = user_fixture("owner@example.com")
    {:ok, owner} = Slipdock.Accounts.update_profile(owner, %{"name" => "Priya Shah"})
    board = board_fixture(%{"name" => "Pricing"}, owner: owner)

    {:ok, _} =
      Settings.update(%{
        "meetings_transcription" => "provider",
        "meetings_transcription_minutes_enabled" => false
      })

    Slipdock.TestConfig.merge(:meetings, ffmpeg: false)
    %{owner: owner, board: board}
  end

  # An 8 kHz, 8-bit mono WAV: 8000 bytes a second.
  defp wav(seconds) do
    rate = 8_000
    data = seconds * rate

    header =
      <<"RIFF", 36 + data::little-32, "WAVE", "fmt ", 16::little-32, 1::little-16, 1::little-16,
        rate::little-32, rate::little-32, 1::little-16, 8::little-16, "data", data::little-32>>

    path = Path.join(System.tmp_dir!(), "a-#{System.unique_integer([:positive])}.wav")
    File.write!(path, [header, :binary.copy(<<128>>, data)])
    on_exit(fn -> File.rm(path) end)
    path
  end

  defp send_audio(board, owner, path, extra \\ %{}) do
    {:ok, capture} =
      Ingest.ingest(
        board,
        owner,
        Map.merge(
          %{audio: %{path: path, filename: Path.basename(path), content_type: "audio/wav"}},
          extra
        )
      )

    capture
  end

  # A transcription endpoint that answers request n with `answer.(n, body)`.
  defp stt(answer) do
    {:ok, counter} = Agent.start_link(fn -> 0 end)
    test = self()

    Req.Test.stub(Slipdock.AI, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn, length: 50_000_000)
      n = Agent.get_and_update(counter, &{&1, &1 + 1})
      send(test, {:stt, conn.request_path, n, body})
      {status, json} = answer.(n, body)
      conn |> Plug.Conn.put_status(status) |> Req.Test.json(json)
    end)
  end

  test "a recording becomes lines, with word confidence, and the seconds and cost go on the ledger",
       %{owner: owner, board: board} do
    stt(fn _, _ ->
      {200,
       %{
         "text" => "Let's ship Friday. Agreed.",
         "segments" => [
           %{"start" => 0.0, "end" => 2.0, "avg_logprob" => -0.1},
           %{"start" => 3.0, "end" => 4.0, "avg_logprob" => -1.5}
         ],
         "words" => [
           %{"word" => "Let's", "start" => 0.0, "end" => 0.4, "probability" => 0.98},
           %{"word" => "ship", "start" => 0.5, "end" => 0.8, "probability" => 0.4},
           %{"word" => "Friday.", "start" => 0.9, "end" => 1.6},
           %{"word" => "Agreed.", "start" => 3.1, "end" => 3.8}
         ],
         "usage" => %{"seconds" => 4.2, "cost" => 0.0007}
       }}
    end)

    capture = Meetings.get_capture!(send_audio(board, owner, wav(5)).id)
    {:ok, capture} = Audio.transcribe(capture, [])

    [one, two] =
      Repo.all(from(u in Utterance, where: u.capture_id == ^capture.id, order_by: u.position))

    assert {one.text, one.start_ms, one.end_ms} == {"Let's ship Friday.", 0, 1600}
    assert {two.text, two.start_ms} == {"Agreed.", 3100}
    assert [%{"confidence" => 0.98}, %{"confidence" => 0.4}, %{"confidence" => c} | _] = one.words
    assert_in_delta c, :math.exp(-0.1), 0.0001
    assert capture.transcript_format == "transcribed"

    assert_received {:stt, "/api/v1/audio/transcriptions", 0, body}
    assert body =~ ~s(name="model") and body =~ "openai/whisper-large-v3"
    assert body =~ ~s(name="response_format") and body =~ "verbose_json"
    assert body =~ ~s(name="prompt") and body =~ "Priya Shah"

    [line] = Enum.filter(Usage.for_capture(capture), &(&1.kind == "transcription"))
    assert line.seconds == 4.2 and line.cost == 0.0007 and line.own_key == false
  end

  test "an 18-minute recording is read in stretches and stitched with no word lost or doubled", %{
    owner: owner,
    board: board
  } do
    Slipdock.TestConfig.merge(:meetings, transcription_max_bytes: 3_000_000)
    path = wav(18 * 60)
    {:ok, stretches} = Transcriber.stretches(path, "long.wav", 18 * 60_000)
    assert length(stretches) == 3
    Enum.each(stretches, &File.rm(&1.path))

    # A word every five seconds, named for its second on the recording's
    # clock; each stretch hears the words it covers, overlap and all.
    stt(fn n, _ ->
      %{offset_ms: offset, length_ms: length} = Enum.at(stretches, n)

      words =
        for second <- 0..1075//5, second * 1000 >= offset, second * 1000 < offset + length do
          rel = (second * 1000 - offset) / 1000
          %{"word" => "t#{second}", "start" => rel, "end" => rel + 0.5}
        end

      {200, %{"words" => words, "usage" => %{"seconds" => length / 1000}}}
    end)

    capture = send_audio(board, owner, path)
    {:ok, capture} = Audio.transcribe(Meetings.get_capture!(capture.id), [])

    said =
      Repo.all(from(u in Utterance, where: u.capture_id == ^capture.id, order_by: u.position))
      |> Enum.flat_map(& &1.words)
      |> Enum.map(& &1["word"])

    assert said == Enum.map(0..1075//5, &"t#{&1}")
    assert length(Enum.filter(Usage.for_capture(capture), &(&1.kind == "transcription"))) == 3
  end

  test "a long recording that isn't WAV, with no ffmpeg, says what to do", %{
    owner: owner,
    board: board
  } do
    Slipdock.TestConfig.merge(:meetings, transcription_max_bytes: 1000)
    path = Path.join(System.tmp_dir!(), "x-#{System.unique_integer([:positive])}.mp3")
    File.write!(path, :binary.copy("x", 5000))
    on_exit(fn -> File.rm(path) end)

    assert {:error, message} = Transcriber.stretches(path, "call.mp3", 60_000)
    assert message =~ "this server can only split WAV files (install ffmpeg for the rest)"
  end

  test "a provider error fails the capture in its words, and retry works", %{
    owner: owner,
    board: board
  } do
    stt(fn _, _ -> {503, %{"error" => %{"message" => "whisper is warming up"}}} end)
    # Received and reading (the test environment leaves the pipeline to us).
    capture = Meetings.get_capture!(send_audio(board, owner, wav(3)).id)
    assert capture.state == "reading"
    capture = Pipeline.run(capture)

    assert capture.state == "failed"
    assert capture.state_reason == "the transcriber said 503: whisper is warming up"

    stt(fn
      0, _ ->
        {200,
         %{
           "text" => "We ship Friday.",
           "segments" => [%{"start" => 0.0, "end" => 2.0, "text" => "We ship Friday."}]
         }}

      _, _ ->
        {200,
         %{"choices" => [%{"message" => %{"content" => ~s({"findings": []})}}], "usage" => %{}}}
    end)

    capture = Pipeline.retry(capture, owner, mode: :sync)
    assert capture.state == "ready"

    assert [%Utterance{text: "We ship Friday."}] =
             Repo.all(from(u in Utterance, where: u.capture_id == ^capture.id))
  end

  test "nothing set up to transcribe: the capture says it needs a transcript", %{
    owner: owner,
    board: board
  } do
    {:ok, _} = Settings.update(%{"meetings_transcription" => "none"})
    capture = send_audio(board, owner, wav(2))

    assert {:error,
            "this server transcribes nothing, so a recording needs a transcript sent with it"} =
             Audio.transcribe(Meetings.get_capture!(capture.id), [])
  end

  test "an endpoint of the admin's is where it goes", %{owner: owner, board: board} do
    {:ok, _} =
      Settings.update(%{
        "meetings_transcription" => "endpoint",
        "meetings_transcription_url" => "http://whisper.example:8000/v1",
        "meetings_transcription_model" => "large-v3"
      })

    stt(fn _, _ -> {200, %{"text" => "Hi."}} end)
    capture = send_audio(board, owner, wav(2))
    {:ok, _} = Audio.transcribe(Meetings.get_capture!(capture.id), [])
    assert_received {:stt, "/v1/audio/transcriptions", 0, body}
    assert body =~ "large-v3"

    assert Meetings.destinations(owner).transcription == %{
             host: "whisper.example",
             model: "large-v3",
             own?: false
           }

    {:error, cs} = Settings.update(%{"meetings_transcription_url" => ""})

    assert %{meetings_transcription_url: ["is needed to transcribe on an endpoint"]} =
             errors_on(cs)
  end

  describe "a transcript sent with the recording" do
    test "with no times of its own is spread over the recording, its text byte for byte", %{
      owner: owner,
      board: board
    } do
      text =
        "Priya: Short.\nSam: A much longer line that takes most of the meeting to say out loud."

      capture = send_audio(board, owner, wav(100), %{transcript: text})
      {:ok, capture} = Audio.transcribe(Meetings.get_capture!(capture.id), [])

      assert capture.transcript == text
      assert capture.sources["alignment"] == "estimated"

      [a, b] =
        Repo.all(from(u in Utterance, where: u.capture_id == ^capture.id, order_by: u.position))

      assert {a.text, b.text} ==
               {"Short.", "A much longer line that takes most of the meeting to say out loud."}

      assert a.start_ms == 0 and b.end_ms == 100_000
      assert b.start_ms > 0 and b.start_ms < 20_000
      refute_received {:stt, _, _, _}
    end

    test "with times of its own is left as it is", %{owner: owner, board: board} do
      vtt = "WEBVTT\n\n00:00:01.000 --> 00:00:02.000\n<v Sam>Hi</v>\n"
      capture = send_audio(board, owner, wav(5), %{transcript: vtt})
      {:ok, capture} = Audio.transcribe(Meetings.get_capture!(capture.id), [])
      assert capture.sources["alignment"] == "from the transcript"

      assert [%Utterance{start_ms: 1000, end_ms: 2000}] =
               Repo.all(from(u in Utterance, where: u.capture_id == ^capture.id))

      assert capture.transcript == vtt
    end
  end

  describe "keeping recordings" do
    test "past their keeping they are deleted, the storage freed, the capture told", %{
      owner: owner,
      board: board
    } do
      kept = send_audio(board, owner, wav(2), %{transcript: "Sam: kept", retention: "30_days"})
      old = send_audio(board, owner, wav(3), %{transcript: "Sam: old", retention: "30_days"})

      Repo.update_all(from(c in Capture, where: c.id == ^old.id),
        set: [inserted_at: ~U[2020-01-01 00:00:00Z]]
      )

      before = Quota.used(owner, :storage)
      path = Meetings.audio_path(Meetings.get_capture!(old.id))

      assert Audio.purge_expired() == 1

      old = Meetings.get_capture!(old.id)
      assert old.audio_key == nil and old.audio_purged_at
      refute File.exists?(path)
      assert Quota.used(owner, :storage) == before - old.audio_size
      assert Meetings.get_capture!(kept.id).audio_key

      assert Repo.exists?(
               from(e in Slipdock.Meetings.Event,
                 where: e.capture_id == ^old.id and e.kind == "audio_deleted"
               )
             )
    end

    test "until committed means until committed, or discarded", %{owner: owner, board: board} do
      capture =
        send_audio(board, owner, wav(2), %{transcript: "Sam: x", retention: "until_committed"})

      assert Audio.purge_expired() == 0
      {:ok, _} = Meetings.discard(Meetings.get_capture!(capture.id), owner)
      assert Audio.purge_expired() == 1
    end
  end
end
