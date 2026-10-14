defmodule Slipdock.Wiki.TranscriptTags do
  @moduledoc """
  The moments a meeting's recording was tagged at, shown in its transcript
  (#785).

  The tool that recorded the meeting writes them into the summary as one
  line,

      Tags: #important (0:05) #action (0:10)

  each a `#tag` and the time into the recording it was pressed at (`m:ss`
  or `h:mm:ss`, seconds may carry a fraction). `parse/1` reads them out of a
  page's body; `place/2` says where each lands in a transcript's turns, so
  `SlipdockWeb.TranscriptView` can draw it inline at that moment.

  A tag in the front matter's `tags:` has no time, so it is not one of these.
  """

  @line ~r/^[ \t]*Tags:[ \t]*(.+)$/mi
  @tag ~r/#([\p{L}\p{N}_\/-]+)[ \t]*\((\d+(?::\d{1,2}){1,2}(?:\.\d+)?)\)/u

  @doc """
  Every timed tag on a page's `Tags:` lines, in time order: `[%{tag:
  "important", ms: 5000}]`. Text that isn't a timed tag is passed over.
  """
  def parse(body) when is_binary(body) do
    @line
    |> Regex.scan(body, capture: :all_but_first)
    |> Enum.flat_map(fn [line] -> Regex.scan(@tag, line, capture: :all_but_first) end)
    |> Enum.flat_map(fn [tag, time] ->
      case ms(time) do
        nil -> []
        ms -> [%{tag: tag, ms: ms}]
      end
    end)
    |> Enum.sort_by(& &1.ms)
  end

  def parse(_), do: []

  defp ms(time) do
    parts = String.split(time, ":")

    with [_ | _] = numbers <- Enum.map(parts, &Float.parse/1),
         true <- Enum.all?(numbers, &match?({_, ""}, &1)) do
      seconds = Enum.reduce(numbers, 0, fn {n, ""}, acc -> acc * 60 + n end)
      round(seconds * 1000)
    else
      _ -> nil
    end
  end

  @doc """
  Where each tag lands among `turns` (`Slipdock.Wiki.Viewer.transcript/2`'s,
  with their `cues`): `%{{turn_index, line_index} => [{word_index, tag}]}`.

  A tag lands in the cue that is being spoken at its moment, at the word the
  same fraction of the way through: cues carry no word times, so that is a
  guess, and the chip says the exact time. A tag in a silence goes before
  the next cue's first word, and one after the last cue at the end of it.
  """
  def place(_turns, []), do: %{}

  def place(turns, tags) do
    cues =
      for {turn, t} <- Enum.with_index(turns),
          {cue, l} <- Enum.with_index(Map.get(turn, :cues, [])),
          is_integer(cue.start_ms),
          do: Map.merge(cue, %{at: {t, l}, words: length(words(cue.text))})

    case cues do
      [] ->
        %{}

      cues ->
        tags
        |> Enum.map(fn tag -> {spot(cues, tag.ms), tag} end)
        |> Enum.group_by(fn {{at, _word}, _tag} -> at end, fn {{_at, word}, tag} ->
          {word, tag}
        end)
    end
  end

  defp spot(cues, ms) do
    speaking = Enum.find(cues, &(&1.start_ms <= ms and ms < (&1.end_ms || &1.start_ms)))
    next = Enum.find(cues, &(&1.start_ms > ms))
    last = List.last(cues)

    cond do
      speaking ->
        span = speaking.end_ms - speaking.start_ms
        {speaking.at, round((ms - speaking.start_ms) / span * speaking.words)}

      next ->
        {next.at, 0}

      true ->
        {last.at, last.words}
    end
  end

  @doc "A line's words, as `place/2` counts them."
  def words(text), do: String.split(text, ~r/\s+/u, trim: true)
end
