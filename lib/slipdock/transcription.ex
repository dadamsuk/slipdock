defmodule Slipdock.Transcription do
  @moduledoc """
  Turns a recording attached to a card into text, on the transcription server
  the admin names on the configuration page: any server that answers the
  API described in docs/manual.md, *What a transcription server must speak*.

  This is the simplest client that API allows:

    * **Discovery first.** `GET /v1/status` before every job: a server on
      another major `api_version` is refused, and the `capabilities` it
      lists decide what is asked for. With `diarization` the transcript
      comes back as `diarized_json`, and is written one speaker turn a line.
    * **One `Idempotency-Key` per recording**, kept for every retry, so a
      dropped connection never transcribes it twice.
    * **`Prefer: wait=N`**, and either answer is normal: `200` with the text,
      or `202` and a job, polled from 2 s up by half each time to 30 s.
    * **Retries only where section 6 says**: `429` and `503` after
      `Retry-After`, `502` and other `5xx` with backoff, `504 sync_timeout`
      by asking again with the same key. Everything else is the answer.

  Nothing here knows about cards; `transcribe_attachment/1` is the part that
  does, and it runs the job in the background so the page never waits on it.
  """

  require Logger

  alias Slipdock.Boards
  alias Slipdock.Boards.Attachment
  alias Slipdock.Settings

  @api_major "1"
  # How long a request may sit on the server before it answers 202 instead.
  @wait_seconds 60
  @max_attempts 6
  # A job that has not finished by then is given up on, and so is one marked
  # running for longer — a restart in the middle leaves it marked so.
  @deadline_ms 4 * 60 * 60 * 1000
  @stale_after_seconds 4 * 60 * 60

  @doc "Whether an admin has named a transcription server."
  def configured?, do: present?(Settings.get().transcription_server_url)

  @doc """
  Asks the server who it is (`GET /v1/status`): `{:ok, status}` with its
  `version`, `api_version` and `capabilities`, or `{:error, reason}` in words
  an admin can act on. The configuration page's "Test connection" is this.
  """
  def status(opts \\ []) do
    with {:ok, server} <- server(opts) do
      server |> req() |> get_status()
    end
  end

  @doc """
  Transcribes the file at `path`. `{:ok, text}`, or `{:error, reason}`.
  `opts` may name `:filename` and `:content_type`, and `:url`/`:token` in
  place of the configured server.
  """
  def transcribe_file(path, opts \\ []) do
    filename = opts[:filename] || Path.basename(path)

    with {:ok, server} <- server(opts),
         req = req(server),
         {:ok, status} <- get_status(req),
         {:ok, file} <- open(path) do
      diarize? = "diarization" in List.wrap(status["capabilities"])

      form = [
        file: {file, [filename: filename] ++ content_type(opts[:content_type])},
        model: "default",
        response_format: if(diarize?, do: "diarized_json", else: "json")
      ]

      key = Ecto.UUID.generate()
      started = System.monotonic_time(:millisecond)
      submit(req, form, key, 1, started)
    end
  end

  @doc """
  Teaches the server a voice (#1201): `clip` (WAV bytes of one person
  speaking) sent to `POST /v1/voiceprints` with the `name` it should give
  that voice in later transcripts. `{:ok, body}` with the server's answer,
  `{:error, :unsupported}` when the server doesn't list `"voiceprints"` in
  its capabilities, `{:error, {:refused, reason}}` when it won't take this
  clip (a 422: "Multiple speakers", too short), or `{:error, reason}`.
  Options as `transcribe_file/2`.
  """
  def add_voiceprint(clip, name, opts \\ []) when is_binary(clip) and is_binary(name) do
    with {:ok, server} <- server(opts),
         req = req(server),
         {:ok, status} <- get_status(req) do
      if "voiceprints" in List.wrap(status["capabilities"]) do
        form = [
          file: {clip, filename: "voiceprint.wav", content_type: "audio/wav"},
          name: name
        ]

        case Req.post(req, url: "/v1/voiceprints", form_multipart: form) do
          {:ok, %{status: status, body: body}} when status in [200, 201] ->
            {:ok, if(is_map(body), do: body, else: %{})}

          {:ok, %{status: 422} = response} ->
            {:error, {:refused, failure(response)}}

          {:ok, response} ->
            {:error, failure(response)}

          {:error, exception} ->
            {:error, "can't reach the transcription server: #{Exception.message(exception)}"}
        end
      else
        {:error, :unsupported}
      end
    end
  end

  @doc """
  Starts transcribing a recording attached to a card, in the background, and
  returns the attachment marked `running`. When it finishes the attachment
  holds the text (or why there is none) and the board is told.

  `{:error, reason}` when it can't start: `:not_configured`, `:not_audio`, or
  `:running` while an earlier one is still going.
  """
  def transcribe_attachment(%Attachment{} = attachment) do
    cond do
      not configured?() ->
        {:error, :not_configured}

      not Attachment.audio?(attachment) ->
        {:error, :not_audio}

      running?(attachment) ->
        {:error, :running}

      true ->
        {:ok, attachment} =
          Boards.update_attachment_transcript(attachment, %{
            transcript_status: "running",
            transcript_error: nil,
            transcript_started_at: DateTime.utc_now(:second)
          })

        run(fn -> finish(attachment) end)
        {:ok, attachment}
    end
  end

  @doc """
  Whether a transcription of this attachment is under way. One marked running
  for longer than any job is allowed is not: the server was restarted in the
  middle of it, and pressing Transcribe again is the way out.
  """
  def running?(%Attachment{transcript_status: "running", transcript_started_at: at})
      when not is_nil(at),
      do: DateTime.diff(DateTime.utc_now(), at) < @stale_after_seconds

  def running?(_), do: false

  @doc "A reason from `transcribe_attachment/1`, as a person reads it."
  def describe(:not_configured), do: "No transcription server is set up on this Slipdock."
  def describe(:not_audio), do: "Only audio files can be transcribed."
  def describe(:running), do: "It is being transcribed already."

  defp finish(attachment) do
    result =
      transcribe_file(Boards.attachment_path(attachment),
        filename: attachment.filename,
        content_type: attachment.content_type
      )

    attrs =
      case result do
        {:ok, text} ->
          %{transcript_status: "done", transcript: text, transcript_error: nil}

        {:error, reason} ->
          Logger.warning("transcribing attachment #{attachment.id} failed: #{reason}")
          %{transcript_status: "failed", transcript_error: String.slice(reason, 0, 250)}
      end

    # The file may have been deleted while the server worked on it.
    case Slipdock.Repo.get(Attachment, attachment.id) do
      nil -> :ok
      current -> Boards.update_attachment_transcript(current, attrs)
    end
  end

  # In the background, unless the tests ask for it inline.
  defp run(fun) do
    if config()[:async] == false do
      fun.()
    else
      Task.Supervisor.start_child(Slipdock.TaskSupervisor, fun)
    end
  end

  ## The server ---------------------------------------------------------------

  defp server(opts) do
    # The stored settings only for what the caller didn't say.
    url = opts[:url] || Settings.get().transcription_server_url

    token =
      if Keyword.has_key?(opts, :token),
        do: opts[:token],
        else: Settings.get().transcription_server_token

    if present?(url),
      do: {:ok, %{root: root(url), token: token}},
      else: {:error, "no transcription server is set up"}
  end

  # The spec serves everything under `/v1` and `/api/v1`; an admin may paste
  # either base URL, or the bare address, and all three mean the same server.
  defp root(url) do
    url
    |> String.trim()
    |> String.trim_trailing("/")
    |> String.replace(~r{(/api)?/v1$}, "")
  end

  defp req(%{root: root, token: token}) do
    auth = if present?(token), do: [{"authorization", "Bearer #{token}"}], else: []

    Req.new(
      [
        base_url: root,
        headers: auth,
        retry: false,
        redirect: false,
        receive_timeout: (@wait_seconds + 30) * 1000
      ] ++ (config()[:req_options] || [])
    )
  end

  defp get_status(req) do
    case Req.get(req, url: "/v1/status") do
      {:ok, %{status: 200, body: %{"api_version" => version} = body}} ->
        if major(version) == @api_major,
          do: {:ok, body},
          else:
            {:error,
             "the server speaks API #{version}; this Slipdock understands #{@api_major}.x only"}

      {:ok, %{status: 200}} ->
        {:error, "that address answers, but not as a transcription server (no api_version)"}

      {:ok, response} ->
        {:error, failure(response)}

      {:error, exception} ->
        {:error, "can't reach the transcription server: #{Exception.message(exception)}"}
    end
  end

  defp content_type(type) when is_binary(type), do: [content_type: type]
  defp content_type(_), do: []

  defp major(version), do: version |> to_string() |> String.split(".") |> hd()

  # Streamed from disk a megabyte at a time, never read whole: an attachment
  # can be 250 MB. A retry enumerates it again from the start.
  defp open(path) do
    if File.regular?(path),
      do: {:ok, File.stream!(path, 1_048_576)},
      else: {:error, "can't read the recording (it is not on disk)"}
  end

  ## Submitting, and the retries section 6 allows ------------------------------

  defp submit(_req, _form, _key, attempt, _started) when attempt > @max_attempts,
    do: {:error, "the transcription server kept refusing; try again later"}

  defp submit(req, form, key, attempt, started) do
    response =
      Req.post(req,
        url: "/v1/audio/transcriptions",
        form_multipart: form,
        headers: [{"idempotency-key", key}, {"prefer", "wait=#{@wait_seconds}"}]
      )

    case response do
      {:ok, %{status: 200, body: body} = r} ->
        note_ignored(r)
        text(body)

      {:ok, %{status: 202} = r} ->
        poll(req, job_path(r), 2_000, started)

      {:ok, %{status: status} = r} when status in [429, 503] ->
        again(req, form, key, attempt, started, retry_after(r, 10))

      # The work goes on; the same key collects it once it is done (4.2).
      {:ok, %{status: 504} = r} ->
        case job_id(r) do
          nil ->
            again(req, form, key, attempt, started, 5_000)

          id ->
            poll(req, "/v1/transcriptions/#{id}", 2_000, started, fn ->
              again(req, form, key, attempt, started, 5_000)
            end)
        end

      {:ok, %{status: status}} when status >= 500 and attempt <= 3 ->
        again(req, form, key, attempt, started, backoff(attempt))

      {:ok, response} ->
        {:error, failure(response)}

      {:error, _exception} when attempt <= 3 ->
        again(req, form, key, attempt, started, backoff(attempt))

      {:error, exception} ->
        {:error, "can't reach the transcription server: #{Exception.message(exception)}"}
    end
  end

  defp again(req, form, key, attempt, started, delay_ms) do
    if past_deadline?(started) do
      {:error, "the transcription server didn't finish in time"}
    else
      pause(delay_ms)
      submit(req, form, key, attempt + 1, started)
    end
  end

  # 5 s, 15 s, 45 s.
  defp backoff(attempt), do: 5_000 * Integer.pow(3, attempt - 1)

  ## Collecting a job ----------------------------------------------------------

  # `on_missing` is what to do if the job is not there to poll: a server
  # without retained transcriptions (API 1.0) answers 404, and the work is
  # collected by repeating the request instead.
  defp poll(req, path, delay_ms, started, on_missing \\ nil) do
    if past_deadline?(started) do
      {:error, "the transcription server didn't finish in time"}
    else
      pause(delay_ms)
      next = min(round(delay_ms * 1.5), 30_000)

      case Req.get(req, url: path) do
        {:ok, %{status: 200, body: %{"status" => "completed"} = job}} ->
          text(job["result"])

        {:ok, %{status: 200, body: %{"status" => status} = job}}
        when status in ["failed", "cancelled"] ->
          {:error, job_failure(job, status)}

        {:ok, %{status: 200} = r} ->
          poll(req, path, max(retry_after(r, next), next), started, on_missing)

        {:ok, %{status: 404}} when is_function(on_missing, 0) ->
          on_missing.()

        {:ok, %{status: status} = r} when status in [429, 503] or status >= 500 ->
          poll(req, path, max(retry_after(r, next), next), started, on_missing)

        {:ok, response} ->
          {:error, failure(response)}

        {:error, _exception} ->
          poll(req, path, next, started, on_missing)
      end
    end
  end

  defp job_path(response) do
    case Req.Response.get_header(response, "location") do
      [location | _] -> URI.parse(location).path
      [] -> "/v1/transcriptions/#{job_id(response)}"
    end
  end

  defp job_id(%{body: %{"id" => id}}) when is_binary(id), do: id
  defp job_id(%{body: %{"error" => %{"id" => id}}}) when is_binary(id), do: id
  defp job_id(_), do: nil

  defp job_failure(%{"error" => %{"message" => message}}, _status) when is_binary(message),
    do: "the transcription server gave up: #{message}"

  defp job_failure(_job, "cancelled"), do: "the transcription was cancelled on the server"
  defp job_failure(_job, _status), do: "the transcription server gave up on it"

  ## Reading the answer --------------------------------------------------------

  # `diarized_json`: one line per speaker turn, consecutive segments by the
  # same speaker run together, as the spec's own `text` format writes it.
  defp text(%{"segments" => [%{"speaker" => _} | _] = segments}) do
    lines =
      segments
      |> Enum.chunk_by(& &1["speaker"])
      |> Enum.map(fn turn ->
        words = turn |> Enum.map_join(" ", &String.trim(&1["text"] || "")) |> String.trim()
        "#{hd(turn)["speaker"]}: #{words}"
      end)

    {:ok, Enum.join(lines, "\n")}
  end

  defp text(%{"text" => text}) when is_binary(text), do: {:ok, String.trim(text)}
  defp text(text) when is_binary(text), do: {:ok, String.trim(text)}
  defp text(_), do: {:error, "the transcription server's answer had no text in it"}

  # Branch on `code`, never the message (6); the message is still the best
  # thing to show a person.
  defp failure(%{status: status, body: %{"error" => %{} = error}}) do
    code = error["code"] || error["type"]
    message = error["message"] || "no reason given"

    case {status, code} do
      {401, _} -> "the transcription server refused the token (#{message})"
      {403, _} -> "the token may not transcribe on that server (#{message})"
      {413, _} -> "the recording is too large for the transcription server"
      {415, _} -> "the transcription server can't read that kind of audio"
      {422, "audio_too_long"} -> "the recording is longer than the server will take"
      {422, "audio_undecodable"} -> "the transcription server couldn't decode the recording"
      _ -> "the transcription server said #{status}#{if code, do: " #{code}"}: #{message}"
    end
  end

  defp failure(%{status: 401}), do: "the transcription server refused the token"
  defp failure(%{status: 404}), do: "nothing at that address answers as a transcription server"
  defp failure(%{status: status}), do: "the transcription server answered #{status}"

  defp retry_after(response, default_ms) do
    with [value | _] <- Req.Response.get_header(response, "retry-after"),
         {seconds, ""} <- Integer.parse(String.trim(value)) do
      min(seconds, 300) * 1000
    else
      _ -> default_ms
    end
  end

  # A typo in a field name otherwise fails silently (5.3).
  defp note_ignored(response) do
    case Req.Response.get_header(response, "x-manuel-ignored-fields") do
      [fields | _] -> Logger.debug("transcription server ignored fields: #{fields}")
      [] -> :ok
    end
  end

  defp past_deadline?(started),
    do: System.monotonic_time(:millisecond) - started > (config()[:deadline_ms] || @deadline_ms)

  defp pause(ms) do
    if config()[:sleep] == false, do: :ok, else: Process.sleep(ms)
  end

  defp config, do: Slipdock.Config.get(:transcription, [])

  defp present?(value), do: is_binary(value) and String.trim(value) != ""
end
