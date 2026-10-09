defmodule Slipdock.Meetings.Transcriber do
  @moduledoc """
  Turning a recording into transcript lines (pipeline step 2), through any
  OpenAI-compatible transcription endpoint: OpenRouter's
  `/api/v1/audio/transcriptions` (e.g. `openai/whisper-large-v3`), a local
  whisper server, a gateway.

  ## Whose endpoint

  The admin chooses (Configuration › Meetings):

    * `"none"` — this server transcribes nothing; a recording needs a
      transcript sent with it;
    * `"provider"` — the sender's own AI settings: OpenRouter with their key
      (or the server's shared one), or their own endpoint, which goes
      through `Slipdock.Egress` like every endpoint a person types;
    * `"endpoint"` — an endpoint of the admin's (`meetings_transcription_url`).

  ## Long recordings

  A provider takes files up to a size (`meetings_transcription_max_mb`, 25 MB
  by default — OpenAI's). Anything larger is cut into stretches that overlap
  by a few seconds: a WAV here, in Elixir; any other format through `ffmpeg`
  when it is installed (it is turned into WAV first). With neither, the
  capture fails saying so, and a transcript sent with the recording is the
  way round it.

  The stretches are stitched back at the middle of each overlap, word by
  word where the provider gives word timings: every word belongs to exactly
  one stretch, so nothing is lost or said twice at a seam.

  ## What comes back

  Lines (the provider's segments) with their times, and each word's time and
  confidence where the provider gives them — `probability`, or a segment's
  `avg_logprob` as `exp`. The board's vocabulary (members' names, card titles)
  goes along as a `prompt` where the provider takes one. The seconds and the
  cost each call reports go on the usage ledger.
  """
  require Logger

  alias Slipdock.{AI, Repo, Settings}
  alias Slipdock.Accounts.User
  alias Slipdock.Meetings.{Capture, Usage}

  @overlap_ms 5_000

  @doc """
  Where a recording would be sent, or nil when this server transcribes
  nothing: `%{base_url:, target:, api_key:, req_options:, model:, own?:}`.
  `{:error, reason}` when the sender's own settings can't be used.
  """
  def target(%User{} = user) do
    s = Settings.get()

    case s.meetings_transcription do
      "provider" ->
        with {:ok, p} <- AI.provider(user: user) do
          {:ok, Map.merge(p, %{model: s.meetings_transcription_model, own?: AI.Keys.own?(user)})}
        end

      "endpoint" ->
        {:ok,
         %{
           base_url: s.meetings_transcription_url,
           target: nil,
           api_key: nil,
           req_options: [],
           model: s.meetings_transcription_model,
           own?: false
         }}

      _ ->
        nil
    end
  end

  @doc "The largest file sent in one request, in bytes."
  def max_bytes do
    Keyword.get(Slipdock.Config.get(:meetings, []), :transcription_max_bytes) ||
      (Settings.get().meetings_transcription_max_mb || 25) * 1024 * 1024
  end

  @doc """
  Transcribes a capture's recording. `{:ok, lines}` — each
  `%{text:, start_ms:, end_ms:, words:}` — or `{:error, reason}`, the
  provider's own words where it gave some.
  """
  def transcribe(%Capture{} = capture, owner, opts \\ []) do
    path = Slipdock.Meetings.audio_path(capture)

    with {:ok, target} <- target_or_none(owner),
         {:ok, stretches} <-
           stretches(path, capture.audio_filename, capture.audio_duration_ms, opts) do
      vocabulary = vocabulary(capture)

      result =
        Enum.reduce_while(stretches, {:ok, []}, fn stretch, {:ok, done} ->
          case send_stretch(stretch, target, vocabulary, capture) do
            {:ok, words_or_segments} -> {:cont, {:ok, done ++ [{stretch, words_or_segments}]}}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)

      cleanup(stretches, path)

      with {:ok, results} <- result do
        {:ok, stitch(results)}
      end
    end
  end

  defp target_or_none(owner) do
    case target(owner) do
      nil ->
        {:error,
         "this server transcribes nothing, so a recording needs a transcript sent with it"}

      {:ok, t} ->
        {:ok, t}

      {:error, reason} ->
        {:error, "can't transcribe: #{reason}"}
    end
  end

  ## Stretches -------------------------------------------------------------------

  @doc false
  # The recording in pieces a provider will take: `[%{path:, offset_ms:,
  # length_ms:, temp?:}]`. One piece when it fits.
  def stretches(path, filename, duration_ms, opts \\ []) do
    size = File.stat!(path).size
    max = opts[:max_bytes] || max_bytes()
    ext = (filename || path) |> Path.extname() |> String.downcase()

    cond do
      size <= max ->
        {:ok,
         [
           %{
             path: path,
             filename: filename || Path.basename(path),
             offset_ms: 0,
             length_ms: duration_ms,
             temp?: false
           }
         ]}

      ext == ".wav" ->
        split_wav(path, max)

      ffmpeg = ffmpeg() ->
        wav = tmp(".wav")

        case System.cmd(
               ffmpeg,
               ["-v", "error", "-y", "-i", path, "-ac", "1", "-ar", "16000", "-f", "wav", wav],
               stderr_to_stdout: true
             ) do
          {_, 0} ->
            result = split_wav(wav, max)
            File.rm(wav)
            result

          {out, _} ->
            File.rm(wav)
            {:error, "the recording could not be read to split it (#{String.slice(out, 0, 200)})"}
        end

      true ->
        {:error,
         "the recording is #{div(size, 1024 * 1024)} MB, more than the transcriber takes at once " <>
           "(#{div(max, 1024 * 1024)} MB), and this server can only split WAV files (install ffmpeg for " <>
           "the rest) — send it as WAV, or with a transcript"}
    end
  end

  # A WAV cut into stretches of whole frames, each with its own header, each
  # starting a few seconds before the last one ended.
  defp split_wav(path, max) do
    with {:ok,
          %{byte_rate: rate, block_align: align, data_offset: offset, data_size: size, fmt: fmt}} <-
           wav_layout(path) do
      header_size = 44
      chunk_bytes = (max - header_size) |> div(align) |> Kernel.*(align)
      overlap_bytes = div(@overlap_ms * rate, 1000) |> div(align) |> Kernel.*(align)
      stride = chunk_bytes - overlap_bytes

      if stride <= 0 do
        {:error, "the transcriber's size limit is too small to split this recording"}
      else
        {:ok, file} = File.open(path, [:read, :binary])

        stretches =
          Stream.iterate(0, &(&1 + stride))
          |> Enum.take_while(&(&1 < size and (&1 == 0 or &1 + overlap_bytes < size)))
          |> Enum.map(fn start ->
            length = min(chunk_bytes, size - start)
            {:ok, data} = :file.pread(file, offset + start, length)
            out = tmp(".wav")
            File.write!(out, [wav_header(fmt, byte_size(data)), data])

            %{
              path: out,
              filename: Path.basename(out),
              offset_ms: div(start * 1000, rate),
              length_ms: div(length * 1000, rate),
              temp?: true
            }
          end)

        File.close(file)
        {:ok, stretches}
      end
    end
  end

  defp wav_layout(path) do
    {:ok, file} = File.open(path, [:read, :binary])
    {:ok, head} = :file.pread(file, 0, 65_536)
    File.close(file)

    case head do
      <<"RIFF", _::32, "WAVE", rest::binary>> -> walk(rest, 12, nil)
      _ -> {:error, "the recording is not a WAV file it can split"}
    end
  end

  defp walk(<<"fmt ", size::little-32, fmt::binary-size(size), rest::binary>>, at, _),
    do: walk(rest, at + 8 + size, fmt)

  defp walk(<<"data", size::little-32, _::binary>>, at, fmt) when is_binary(fmt) do
    <<_format::little-16, _channels::little-16, _rate::little-32, byte_rate::little-32,
      align::little-16, _::binary>> = fmt

    {:ok,
     %{
       byte_rate: byte_rate,
       block_align: max(align, 1),
       data_offset: at + 8,
       data_size: size,
       fmt: fmt
     }}
  end

  defp walk(<<_::binary-size(4), size::little-32, rest::binary>>, at, fmt)
       when byte_size(rest) >= size do
    <<_::binary-size(^size), more::binary>> = rest
    walk(more, at + 8 + size, fmt)
  end

  defp walk(_, _, _), do: {:error, "the recording's WAV header could not be read"}

  defp wav_header(fmt, data_size) do
    fmt16 = binary_part(fmt, 0, 16)

    <<"RIFF", 36 + data_size::little-32, "WAVE", "fmt ", 16::little-32, fmt16::binary, "data",
      data_size::little-32>>
  end

  # Config can say `ffmpeg: false` (the tests do, so they don't depend on
  # what the machine has installed) or name a path.
  defp ffmpeg do
    case Keyword.get(Slipdock.Config.get(:meetings, []), :ffmpeg, :find) do
      :find -> System.find_executable("ffmpeg")
      false -> nil
      path -> path
    end
  end

  defp tmp(ext),
    do: Path.join(System.tmp_dir!(), "slipdock-stt-#{System.unique_integer([:positive])}#{ext}")

  defp cleanup(stretches, _path) do
    for %{temp?: true, path: p} <- stretches, do: File.rm(p)
    :ok
  end

  ## One request -----------------------------------------------------------------

  defp send_stretch(stretch, target, vocabulary, capture) do
    fields =
      [
        file: {File.read!(stretch.path), filename: stretch.filename},
        model: target.model,
        response_format: "verbose_json",
        "timestamp_granularities[]": "word",
        "timestamp_granularities[]": "segment"
      ] ++ if(vocabulary != "", do: [prompt: vocabulary], else: [])

    started = System.monotonic_time(:millisecond)

    case Req.post(AI.request(target),
           url: "/audio/transcriptions",
           form_multipart: fields,
           receive_timeout: 600_000
         ) do
      {:ok, %Req.Response{status: 200, body: %{} = body}} ->
        seconds =
          get_in(body, ["usage", "seconds"]) || body["duration"] ||
            (stretch.length_ms && stretch.length_ms / 1000)

        Usage.record(capture, %{
          kind: :transcription,
          step: "transcribe",
          seconds: seconds,
          cost: get_in(body, ["usage", "cost"]),
          model: target.model,
          own_key: target.own?
        })

        Logger.info(
          "Transcribed #{round((seconds || 0) / 1)}s in #{System.monotonic_time(:millisecond) - started}ms"
        )

        {:ok, body}

      {:ok, %Req.Response{status: 200, body: text}} when is_binary(text) ->
        {:ok, %{"text" => text}}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, "the transcriber said #{status}: #{provider_message(body)}"}

      {:error, exception} ->
        {:error, "couldn't reach the transcriber (#{Exception.message(exception)})"}
    end
  end

  defp provider_message(%{"error" => %{"message" => m}}), do: m
  defp provider_message(%{"error" => m}) when is_binary(m), do: m
  defp provider_message(%{"message" => m}) when is_binary(m), do: m
  defp provider_message(body) when is_binary(body), do: String.slice(body, 0, 200)
  defp provider_message(body), do: inspect(body) |> String.slice(0, 200)

  # Names and titles the meeting is likely to say, to steer the spelling.
  defp vocabulary(%Capture{board_id: board_id}) do
    import Ecto.Query

    board = Repo.get!(Slipdock.Boards.Board, board_id)

    people =
      board |> Slipdock.Wiki.Links.members() |> Enum.map(& &1.name) |> Enum.reject(&is_nil/1)

    cards =
      Repo.all(
        from(c in Slipdock.Boards.Card,
          where: c.board_id == ^board_id and is_nil(c.archived_at),
          order_by: [desc: c.updated_at],
          limit: 40,
          select: c.title
        )
      )

    (people ++ cards) |> Enum.uniq() |> Enum.join(", ") |> String.slice(0, 800)
  end

  ## Stitching -------------------------------------------------------------------

  @doc false
  # Every stretch's lines on the recording's own clock, each word kept by
  # exactly one stretch: the one whose half of the overlap it starts in.
  def stitch(results) do
    count = length(results)

    results
    |> Enum.with_index()
    |> Enum.flat_map(fn {{stretch, body}, i} ->
      from = if i == 0, do: nil, else: cut(Enum.at(results, i - 1), stretch)

      until =
        if i == count - 1, do: nil, else: cut({stretch, body}, elem(Enum.at(results, i + 1), 0))

      lines(body, stretch.offset_ms, from, until)
    end)
    |> Enum.reject(&(&1.text == ""))
  end

  # The middle of the overlap between a stretch and the next.
  defp cut({stretch, _body}, next) do
    ends = stretch.offset_ms + (stretch.length_ms || 0)
    div(next.offset_ms + ends, 2)
  end

  defp lines(body, offset, from, until) do
    keep? = fn start -> (from == nil or start >= from) and (until == nil or start < until) end
    segments = body["segments"] || []
    words = body["words"] || []

    cond do
      words != [] ->
        words =
          words
          |> Enum.map(fn w ->
            %{
              "word" => String.trim(w["word"] || ""),
              "start_ms" => ms(w["start"], offset),
              "end_ms" => ms(w["end"], offset),
              "confidence" => w["probability"] || w["confidence"]
            }
          end)
          |> Enum.filter(&keep?.(&1["start_ms"]))

        group(words, segments, offset)

      segments != [] ->
        segments
        |> Enum.map(fn s ->
          %{
            text: String.trim(s["text"] || ""),
            start_ms: ms(s["start"], offset),
            end_ms: ms(s["end"], offset),
            words: nil,
            confidence: s["avg_logprob"] && :math.exp(s["avg_logprob"])
          }
        end)
        |> Enum.filter(&keep?.(&1.start_ms))
        |> Enum.map(&Map.delete(&1, :confidence))

      true ->
        text = String.trim(body["text"] || "")

        if keep?.(offset),
          do: [%{text: text, start_ms: offset, end_ms: nil, words: nil}],
          else: []
    end
  end

  # Words into the provider's segments when it gave some, else into lines at
  # pauses of a second or more.
  defp group(words, segments, offset) do
    spans =
      Enum.map(segments, fn s ->
        {ms(s["start"], offset), ms(s["end"], offset),
         s["avg_logprob"] && :math.exp(s["avg_logprob"])}
      end)

    words
    |> Enum.chunk_while(
      [],
      fn w, acc ->
        case acc do
          [] ->
            {:cont, [w]}

          [last | _] ->
            if new_line?(last, w, spans),
              do: {:cont, Enum.reverse(acc), [w]},
              else: {:cont, [w | acc]}
        end
      end,
      fn
        [] -> {:cont, []}
        acc -> {:cont, Enum.reverse(acc), []}
      end
    )
    |> Enum.map(fn ws ->
      span =
        Enum.find(spans, fn {s, e, _} -> hd(ws)["start_ms"] >= s and hd(ws)["start_ms"] < e end)

      ws =
        Enum.map(ws, fn w ->
          if is_nil(w["confidence"]) and span,
            do: Map.put(w, "confidence", elem(span, 2)),
            else: w
        end)

      %{
        text:
          ws
          |> Enum.map_join(" ", & &1["word"])
          |> String.replace(~r/\s+([,.!?;:])/, "\\1")
          |> String.trim(),
        start_ms: hd(ws)["start_ms"],
        end_ms: List.last(ws)["end_ms"],
        words: ws
      }
    end)
  end

  defp new_line?(last, w, []), do: w["start_ms"] - (last["end_ms"] || last["start_ms"]) >= 1_000

  defp new_line?(last, w, spans) do
    index = fn word ->
      Enum.find_index(spans, fn {s, e, _} -> word["start_ms"] >= s and word["start_ms"] < e end)
    end

    index.(last) != index.(w)
  end

  defp ms(nil, _offset), do: nil
  defp ms(seconds, offset) when is_number(seconds), do: offset + round(seconds * 1000)
end
