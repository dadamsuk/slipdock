defmodule Slipdock.Meetings.Relisten do
  @moduledoc """
  Pipeline step 8: listening again to the passages a finding depends on that
  were unclear — words the transcriber was unsure of, or a passage the two
  readings heard differently.

  Each such passage is cut from the recording (a WAV here; other formats
  through ffmpeg when it is installed) and sent to an audio-capable model
  (`meetings_relisten_model`; off when unset) with the board's vocabulary and
  the competing readings. What comes back is **a signal, never an
  override**:

    * it agrees with the transcript — the passage is marked *re-listened*;
    * it hears something else — a question for a person (`unclear`), with
      both versions and "not sure" as answers;
    * a question the readings already raised keeps it, with what the model
      heard attached as *the model's view*, labelled a guess.

  Nothing happens without a recording, or with re-listening off.
  """
  require Logger

  import Ecto.Query, warn: false

  alias Slipdock.{AI, Meetings, Repo, Settings}
  alias Slipdock.Meetings.{Capture, Finding, Question, Usage, Utterance}

  @unsure_below 0.6
  @pad_ms 1_000

  @doc "Re-listens where it matters (step 8)."
  def run(%Capture{} = capture, opts \\ []) do
    model = Settings.get().meetings_relisten_model
    path = Meetings.audio_path(capture)

    if blank?(model) or is_nil(path) or not File.regular?(path) do
      {:ok, capture}
    else
      owner = Repo.get!(Slipdock.Accounts.User, capture.owner_id)

      capture
      |> passages()
      |> Enum.each(fn passage -> relisten(capture, owner, model, path, passage, opts) end)

      {:ok, capture}
    end
  end

  defp blank?(nil), do: true
  defp blank?(s), do: String.trim(s) == ""

  # The lines a kept finding depends on that are worth listening to again:
  # unsure words, or a which-reading question about them.
  defp passages(capture) do
    findings =
      Repo.all(
        from(f in Finding,
          where: f.capture_id == ^capture.id and f.status == "kept",
          preload: [evidence: :utterance, questions: []]
        )
      )

    # (A binding in a `for` is also a filter, so the question is looked for
    # inside: a finding with none still counts when its words were unsure.)
    findings
    |> Enum.flat_map(fn f ->
      line = f.evidence |> List.first() |> then(&(&1 && &1.utterance))
      question = Enum.find(f.questions, &(&1.kind == "which_reading" and &1.status == "open"))

      if line && line.start_ms && (question || unsure_words?(line)),
        do: [%{finding: f, line: line, question: question}],
        else: []
    end)
  end

  defp unsure_words?(%Utterance{words: words}) when is_list(words),
    do: Enum.any?(words, &((&1["confidence"] || 1.0) < @unsure_below))

  defp unsure_words?(_), do: false

  defp relisten(capture, owner, model, path, %{finding: f, line: line, question: question}, opts) do
    from = max(line.start_ms - @pad_ms, 0)
    to = (line.end_ms || line.start_ms + 5_000) + @pad_ms

    with {:ok, clip} <- clip(path, capture.audio_filename, from, to),
         {:ok, heard} <- ask(capture, owner, model, clip, line, question, opts) do
      apply_result(capture, f, line, question, heard, model, {from, to})
    else
      {:error, reason} ->
        Logger.info("Re-listening to #{line.line_id} of capture #{capture.id} skipped: #{reason}")
    end
  end

  defp ask(capture, owner, model, clip, line, question, opts) do
    readings =
      case question do
        %Question{options: options} ->
          options
          |> Enum.reject(&(&1["value"] == "none"))
          |> Enum.with_index()
          |> Enum.map_join("\n", fn {o, i} -> "#{<<?A + i>>}: #{o["label"]}" end)

        nil ->
          "A: #{line.text}"
      end

    prompt = """
    This is a short clip from a work meeting. Listen to it and say exactly what
    is said. The transcript has: “#{line.text}”. Readings to choose between:
    #{readings}
    Names and terms that may come up: #{vocabulary(capture)}
    Answer with one JSON object: {"heard": "the words as you hear them",
    "matches": "A", "B", … or "neither"}.
    """

    ai_opts =
      [
        user: owner,
        model: model,
        max_tokens: 400,
        temperature: 0.0,
        on_usage: Usage.recorder(capture, :relisten, "relisten", AI.Keys.own?(owner))
      ]
      |> Keyword.merge(opts[:ai] || [])

    messages = [
      %{
        role: "user",
        content: [
          %{"type" => "text", "text" => prompt},
          %{
            "type" => "input_audio",
            "input_audio" => %{"data" => Base.encode64(clip), "format" => "wav"}
          }
        ]
      }
    ]

    case AI.complete_json(messages, ai_opts) do
      {:ok, %{"heard" => heard} = answer} when is_binary(heard) -> {:ok, answer}
      {:ok, _} -> {:error, "the model's answer had no \"heard\""}
      {:error, reason} -> {:error, reason}
    end
  end

  defp vocabulary(capture) do
    board = Repo.get!(Slipdock.Boards.Board, capture.board_id)
    board |> Slipdock.Wiki.Links.members() |> Enum.map(&(&1.name || &1.email)) |> Enum.join(", ")
  end

  # A signal, never an override.
  defp apply_result(capture, f, line, question, heard, model, {from, to}) do
    view = %{
      "heard" => heard["heard"],
      "matches" => heard["matches"],
      "model" => model,
      "span" => [from, to]
    }

    cond do
      question ->
        question
        |> Ecto.Changeset.change(context: Map.put(question.context, "model_view", view))
        |> Repo.update!()

        signal(f, "relistened")

      same?(heard["heard"], line.text) or heard["matches"] == "A" ->
        signal(f, "relistened")

      true ->
        Repo.insert!(%Question{
          capture_id: capture.id,
          finding_id: f.id,
          kind: "unclear",
          prompt:
            "The recording is unclear at #{clock(line.start_ms)} (#{line.line_id}). What was said?",
          options: [
            %{
              "value" => "transcript",
              "label" => line.text,
              "effect" => "keep the transcript's words"
            },
            %{
              "value" => "heard",
              "label" => heard["heard"],
              "effect" => "the words were these; check the finding still holds"
            },
            %{"value" => "none", "label" => "Not sure", "effect" => "leave it as uncertain"}
          ],
          context: %{"line" => line.line_id, "model_view" => view}
        })

        signal(f, "audio_unclear")
    end
  end

  defp signal(f, s),
    do: f |> Ecto.Changeset.change(signals: Enum.uniq(f.signals ++ [s])) |> Repo.update!()

  defp same?(a, b) do
    norm = &(&1 |> String.downcase() |> String.replace(~r/[^\p{L}\p{N}]+/u, " ") |> String.trim())
    norm.(a) == norm.(b)
  end

  defp clock(ms) do
    s = div(ms, 1000)
    "#{div(s, 60)}:#{String.pad_leading(Integer.to_string(rem(s, 60)), 2, "0")}"
  end

  ## Clips --------------------------------------------------------------------

  @doc false
  # The stretch from `from` to `to` (ms) as a WAV: cut from a WAV here, or
  # through ffmpeg from anything else when it is installed.
  def clip(path, filename, from, to) do
    ext = (filename || path) |> Path.extname() |> String.downcase()

    cond do
      ext == ".wav" -> wav_clip(path, from, to)
      ffmpeg = ffmpeg() -> ffmpeg_clip(ffmpeg, path, from, to)
      true -> {:error, "only WAV recordings can be cut without ffmpeg"}
    end
  end

  defp wav_clip(path, from, to) do
    {:ok, file} = File.open(path, [:read, :binary])
    {:ok, head} = :file.pread(file, 0, 65_536)

    result =
      with {:ok, fmt, offset, size} <- layout(head, 12, nil) do
        <<_::little-16, _::little-16, _::little-32, rate::little-32, align::little-16, _::binary>> =
          fmt

        align = max(align, 1)
        start = min(div(from * rate, 1000) |> div(align) |> Kernel.*(align), size)
        stop = min(div(to * rate, 1000) |> div(align) |> Kernel.*(align), size)
        {:ok, data} = :file.pread(file, offset + start, max(stop - start, 0))
        fmt16 = binary_part(fmt, 0, 16)

        {:ok,
         IO.iodata_to_binary([
           <<"RIFF", 36 + byte_size(data)::little-32, "WAVE", "fmt ", 16::little-32>>,
           fmt16,
           <<"data", byte_size(data)::little-32>>,
           data
         ])}
      end

    File.close(file)
    result
  end

  defp layout(<<"RIFF", _::32, "WAVE", rest::binary>>, at, fmt), do: layout(rest, at, fmt)

  defp layout(<<"fmt ", size::little-32, fmt::binary-size(size), rest::binary>>, at, _),
    do: layout(rest, at + 8 + size, fmt)

  defp layout(<<"data", size::little-32, _::binary>>, at, fmt) when is_binary(fmt),
    do: {:ok, fmt, at + 8, size}

  defp layout(<<_::binary-size(4), size::little-32, rest::binary>>, at, fmt)
       when byte_size(rest) >= size do
    <<_::binary-size(^size), more::binary>> = rest
    layout(more, at + 8 + size, fmt)
  end

  defp layout(_, _, _), do: {:error, "the recording's WAV header could not be read"}

  defp ffmpeg_clip(ffmpeg, path, from, to) do
    out = Path.join(System.tmp_dir!(), "slipdock-clip-#{System.unique_integer([:positive])}.wav")

    args = [
      "-v",
      "error",
      "-y",
      "-ss",
      "#{from / 1000}",
      "-to",
      "#{to / 1000}",
      "-i",
      path,
      "-ac",
      "1",
      "-ar",
      "16000",
      out
    ]

    try do
      case System.cmd(ffmpeg, args, stderr_to_stdout: true) do
        {_, 0} -> File.read(out)
        {err, _} -> {:error, String.slice(err, 0, 200)}
      end
    after
      File.rm(out)
    end
  end

  defp ffmpeg do
    case Keyword.get(Slipdock.Config.get(:meetings, []), :ffmpeg, :find) do
      :find -> System.find_executable("ffmpeg")
      false -> nil
      path -> path
    end
  end
end
