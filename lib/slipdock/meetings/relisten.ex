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
  defdelegate clip(path, filename, from, to), to: Slipdock.Transcription.Voiceprints
end
