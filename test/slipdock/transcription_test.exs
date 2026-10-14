defmodule Slipdock.TranscriptionTest do
  @moduledoc """
  `Slipdock.Transcription` against a scripted transcription server: discovery, the
  answers it can give (200, 202 and a job, the retryable refusals and the
  final ones), and the card attachment it writes the result to.
  """
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Boards, Settings, Transcription}

  @url "https://transcribe.example:8765"
  @status %{
    "version" => "2.4.0",
    "api_version" => "1.0.0",
    "capabilities" => ["priority", "idempotency"]
  }

  setup do
    Slipdock.TestConfig.own_uploads_dir()
    path = Path.join(System.tmp_dir!(), "call-#{System.unique_integer([:positive])}.mp3")
    File.write!(path, "ID3 fake audio")
    on_exit(fn -> File.rm(path) end)
    %{path: path}
  end

  # Scripts the server: `status` answers GET /v1/status; each POST and each
  # job GET takes the next of `answers` ({status, body} or {status, body,
  # headers}). Every request is sent to the test as {:server, method, path,
  # headers, body}.
  defp serve(answers, status \\ @status) do
    test = self()
    {:ok, agent} = Agent.start_link(fn -> answers end)

    Req.Test.stub(Transcription, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test, {:server, conn.method, conn.request_path, conn.req_headers, body})

      if conn.request_path == "/v1/status" do
        Req.Test.json(conn, status)
      else
        case Agent.get_and_update(agent, fn [next | rest] -> {next, rest} end) do
          {code, reply} -> answer(conn, code, reply, [])
          {code, reply, headers} -> answer(conn, code, reply, headers)
        end
      end
    end)
  end

  defp answer(conn, code, reply, headers) do
    conn = Enum.reduce(headers, conn, fn {k, v}, c -> Plug.Conn.put_resp_header(c, k, v) end)

    if is_binary(reply),
      do: Plug.Conn.send_resp(conn, code, reply),
      else: conn |> Plug.Conn.put_status(code) |> Req.Test.json(reply)
  end

  defp header(headers, name), do: for({^name, v} <- headers, do: v)

  defp transcribe(path), do: Transcription.transcribe_file(path, url: @url, token: "k3y")

  describe "a transcription" do
    test "sends the file with a key, a wait and the token, and reads the text", %{path: path} do
      serve([{200, %{"text" => " Hello there. ", "id" => "trn_1"}}])

      assert {:ok, "Hello there."} = transcribe(path)

      assert_received {:server, "GET", "/v1/status", headers, _}
      assert header(headers, "authorization") == ["Bearer k3y"]

      assert_received {:server, "POST", "/v1/audio/transcriptions", headers, body}
      assert header(headers, "authorization") == ["Bearer k3y"]
      assert header(headers, "prefer") == ["wait=60"]
      assert [key] = header(headers, "idempotency-key")
      assert {:ok, _} = Ecto.UUID.cast(key)
      assert body =~ "ID3 fake audio"
      assert body =~ ~s(name="model"\r\n\r\ndefault)
      assert body =~ ~s(name="response_format"\r\n\r\njson)
    end

    # Over a real socket: Req.Test's plug adapter carries no streamed body this
    # size, so the stub would see nothing whatever the client sent.
    test "a recording larger than one read is streamed to the server whole" do
      bytes = for n <- 0..(3 * 1_048_576 + 7), into: <<>>, do: <<rem(n, 251)>>
      path = Path.join(System.tmp_dir!(), "long-#{System.unique_integer([:positive])}.mp3")
      File.write!(path, bytes)
      on_exit(fn -> File.rm(path) end)

      Slipdock.TestConfig.merge(:transcription, req_options: [])

      {:ok, server} =
        Bandit.start_link(
          plug: {__MODULE__.Server, self()},
          ip: {127, 0, 0, 1},
          port: 0,
          startup_log: false
        )

      {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
      on_exit(fn -> Process.exit(server, :normal) end)

      assert {:ok, "ok"} =
               Transcription.transcribe_file(path, url: "http://127.0.0.1:#{port}", token: nil)

      assert_received {:posted, body}
      assert :binary.match(body, bytes) != :nomatch
    end

    test "with diarisation on offer, writes one speaker turn a line", %{path: path} do
      serve(
        [
          {200,
           %{
             "text" => "Hi. Hello John. How are you?",
             "segments" => [
               %{"speaker" => "Steve", "speaker_id" => "S1", "text" => " Hi."},
               %{"speaker" => "John", "speaker_id" => "S2", "text" => "Hello"},
               %{"speaker" => "John", "speaker_id" => "S2", "text" => " John."},
               %{"speaker" => "Steve", "speaker_id" => "S1", "text" => "How are you?"}
             ]
           }}
        ],
        Map.put(@status, "capabilities", ["diarization"])
      )

      assert {:ok, "Steve: Hi.\nJohn: Hello John.\nSteve: How are you?"} = transcribe(path)
      assert_received {:server, "POST", _, _, body}
      assert body =~ ~s(name="response_format"\r\n\r\ndiarized_json)
    end

    test "a bare base URL, /v1 and /api/v1 all reach the same paths", %{path: path} do
      for url <- [@url, @url <> "/", @url <> "/v1", @url <> "/api/v1/"] do
        serve([{200, %{"text" => "ok"}}])
        assert {:ok, "ok"} = Transcription.transcribe_file(path, url: url, token: nil)
        assert_received {:server, "GET", "/v1/status", headers, _}
        assert header(headers, "authorization") == []
        assert_received {:server, "POST", "/v1/audio/transcriptions", _, _}
      end
    end

    test "a 202 is a job, polled until it completes", %{path: path} do
      serve([
        {202, %{"id" => "trn_9", "status" => "queued"},
         [{"location", "/v1/transcriptions/trn_9"}]},
        {200, %{"id" => "trn_9", "status" => "queued", "queue_position" => 2}},
        {200, %{"id" => "trn_9", "status" => "processing"}},
        {200, %{"id" => "trn_9", "status" => "completed", "result" => %{"text" => "Done."}}}
      ])

      assert {:ok, "Done."} = transcribe(path)
      assert_received {:server, "POST", "/v1/audio/transcriptions", _, _}

      for _ <- 1..3,
          do: assert_received({:server, "GET", "/v1/transcriptions/trn_9", _, _})
    end

    test "a job that fails says why", %{path: path} do
      serve([
        {202, %{"id" => "trn_9"}},
        {200,
         %{"id" => "trn_9", "status" => "failed", "error" => %{"message" => "decoder crashed"}}}
      ])

      assert {:error, "the transcription server gave up: decoder crashed"} = transcribe(path)
    end

    test "queue full, a model loading and a 502 are tried again with the same key", %{
      path: path
    } do
      serve([
        {429, %{"error" => %{"code" => "queue_full", "message" => "busy"}},
         [{"retry-after", "3"}]},
        {503, %{"error" => %{"code" => "model_loading", "message" => "loading"}}},
        {502, %{"error" => %{"code" => "upstream_error", "message" => "cloud"}}},
        {200, %{"text" => "Third time lucky."}}
      ])

      assert {:ok, "Third time lucky."} = transcribe(path)

      keys =
        for _ <- 1..4 do
          assert_received {:server, "POST", _, headers, _}
          header(headers, "idempotency-key")
        end

      assert keys |> Enum.uniq() |> length() == 1
    end

    test "a 504 sync_timeout is collected by asking again with the same key", %{path: path} do
      serve([
        {504, %{"error" => %{"code" => "sync_timeout", "message" => "still going"}}},
        {200, %{"text" => "Collected."}, [{"idempotent-replayed", "true"}]}
      ])

      assert {:ok, "Collected."} = transcribe(path)
      assert_received {:server, "POST", _, h1, _}
      assert_received {:server, "POST", _, h2, _}
      assert header(h1, "idempotency-key") == header(h2, "idempotency-key")
    end

    test "a 504 with a job id polls it, and repeats the request if it can't be fetched", %{
      path: path
    } do
      serve([
        {504, %{"id" => "trn_5", "error" => %{"code" => "sync_timeout", "message" => "going"}}},
        {404, %{"error" => %{"code" => "not_found", "message" => "no such"}}},
        {200, %{"text" => "Replayed."}}
      ])

      assert {:ok, "Replayed."} = transcribe(path)
      assert_received {:server, "GET", "/v1/transcriptions/trn_5", _, _}
    end

    test "a server that keeps refusing is given up on", %{path: path} do
      serve(List.duplicate({503, %{"error" => %{"code" => "engine_unavailable"}}}, 10))

      assert {:error, "the transcription server kept refusing; try again later"} =
               transcribe(path)
    end

    test "the final refusals come back in words, and are not retried", %{path: path} do
      for {code, error, expected} <- [
            {401, %{"code" => "invalid_api_key", "message" => "bad key"},
             "the transcription server refused the token (bad key)"},
            {403, %{"code" => "scope", "message" => "no transcribe scope"},
             "the token may not transcribe on that server (no transcribe scope)"},
            {413, %{"code" => "upload_too_large"},
             "the recording is too large for the transcription server"},
            {415, %{"code" => "unsupported_audio_format"},
             "the transcription server can't read that kind of audio"},
            {422, %{"code" => "audio_undecodable"},
             "the transcription server couldn't decode the recording"},
            {422, %{"code" => "audio_too_long"},
             "the recording is longer than the server will take"},
            {400, %{"code" => "invalid_parameter", "message" => "model"},
             "the transcription server said 400 invalid_parameter: model"}
          ] do
        serve([{code, %{"error" => error}}, {200, %{"text" => "never"}}])
        assert {:error, ^expected} = transcribe(path)
        assert_received {:server, "POST", _, _, _}
        refute_received {:server, "POST", _, _, _}
      end
    end

    test "a server on another major API version is refused before anything is sent", %{
      path: path
    } do
      serve([{200, %{"text" => "never"}}], Map.put(@status, "api_version", "2.0.0"))

      assert {:error, "the server speaks API 2.0.0; this Slipdock understands 1.x only"} =
               transcribe(path)

      refute_received {:server, "POST", _, _, _}
    end

    test "something that isn't a transcription server says so", %{path: path} do
      serve([], %{"hello" => "world"})

      assert {:error, "that address answers, but not as a transcription server" <> _} =
               transcribe(path)
    end

    test "no server set up, or a file that is gone, is an error", %{path: path} do
      assert {:error, "no transcription server is set up"} =
               Transcription.transcribe_file(path)

      serve([])

      assert {:error, "can't read the recording (it is not on disk)"} =
               transcribe(path <> ".gone")
    end
  end

  describe "status/1" do
    test "is the server's own account of itself" do
      serve([])
      assert {:ok, %{"version" => "2.4.0"}} = Transcription.status(url: @url, token: "k3y")
    end
  end

  describe "a recording on a card" do
    setup %{path: path} do
      board = board_fixture()
      card = card_fixture(hd(board.columns))

      {:ok, audio} =
        Boards.add_attachment(card, %{filename: "call.mp3", content_type: "audio/mpeg"}, path)

      {:ok, pdf} =
        Boards.add_attachment(card, %{filename: "a.pdf", content_type: "application/pdf"}, path)

      %{audio: audio, pdf: pdf}
    end

    test "needs a server to be set up", %{audio: audio} do
      assert {:error, :not_configured} = Transcription.transcribe_attachment(audio)
      refute Transcription.configured?()
    end

    test "is transcribed, and the text kept on it", %{audio: audio} do
      {:ok, _} =
        Settings.update(%{transcription_server_url: @url, transcription_server_token: "k3y"})

      serve([{200, %{"text" => "Minutes of the call."}}])

      assert {:ok, %{transcript_status: "running"}} = Transcription.transcribe_attachment(audio)

      audio = Boards.get_attachment!(audio.id)
      assert audio.transcript_status == "done"
      assert audio.transcript == "Minutes of the call."
      assert audio.transcript_error == nil

      assert_received {:server, "POST", _, _, body}
      assert body =~ ~s(filename="call.mp3")
      assert body =~ "content-type: audio/mpeg"
    end

    test "a failure is kept on it, and it can be tried again", %{audio: audio} do
      {:ok, _} = Settings.update(%{transcription_server_url: @url})
      serve([{401, %{"error" => %{"code" => "invalid_api_key", "message" => "bad"}}}])

      {:ok, _} = Transcription.transcribe_attachment(audio)
      audio = Boards.get_attachment!(audio.id)
      assert audio.transcript_status == "failed"
      assert audio.transcript_error =~ "refused the token"

      serve([{200, %{"text" => "Second go."}}])
      {:ok, _} = Transcription.transcribe_attachment(audio)

      assert %{transcript_status: "done", transcript_error: nil, transcript: "Second go."} =
               Boards.get_attachment!(audio.id)
    end

    test "only audio, and not while one is running", %{audio: audio, pdf: pdf} do
      {:ok, _} = Settings.update(%{transcription_server_url: @url})

      assert {:error, :not_audio} = Transcription.transcribe_attachment(pdf)

      {:ok, running} =
        Boards.update_attachment_transcript(audio, %{
          transcript_status: "running",
          transcript_started_at: DateTime.utc_now(:second)
        })

      assert Transcription.running?(running)
      assert {:error, :running} = Transcription.transcribe_attachment(running)

      # One left running by a restart, hours ago, may be started again.
      {:ok, stale} =
        Boards.update_attachment_transcript(running, %{
          transcript_started_at: DateTime.add(DateTime.utc_now(:second), -5 * 3600)
        })

      refute Transcription.running?(stale)
      serve([{200, %{"text" => "Fresh."}}])
      assert {:ok, _} = Transcription.transcribe_attachment(stale)
      assert Boards.get_attachment!(audio.id).transcript == "Fresh."
    end
  end
end

defmodule Slipdock.TranscriptionTest.Server do
  @moduledoc false
  # Just enough of a transcription server, on a real socket, to receive an upload.
  import Plug.Conn

  def init(test), do: test

  def call(%{request_path: "/v1/status"} = conn, _test),
    do:
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, ~s({"api_version":"1.0.0"}))

  def call(conn, test) do
    {:ok, body, conn} = read_body(conn, length: 20_000_000)
    send(test, {:posted, body})
    conn |> put_resp_content_type("application/json") |> send_resp(200, ~s({"text":"ok"}))
  end
end
