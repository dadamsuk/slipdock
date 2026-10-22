defmodule Slipdock.Wiki.TranscriptSpeakers do
  @moduledoc """
  Putting a name on a voice in a page's transcript (#1157).

  A transcriber that can't tell who is speaking writes `Speaker 1`,
  `Speaker 2`; whoever listens back knows who they were. `rename/3` changes
  one speaker's name throughout every ` ```vtt ` block in a page's body, so
  the player and anybody reading the page afterwards see the person, and the
  change is an ordinary page revision that can be looked at or undone.

  A cue names its speaker the two ways `Slipdock.Meetings.Transcript` reads:
  a `<v Name>` voice tag, which keeps its place and any class it has, or a
  `Name:` prefix, which becomes a voice tag, because a prefix only reads back
  as a name while it is short and plain. Nothing outside a ` ```vtt ` block
  is touched.
  """

  @fence ~r/^[ \t]*(`{3,}|~{3,})[ \t]*vtt[ \t]*$/
  @cue_time ~r/^\s*(?:\d{1,2}:)?\d{1,2}:\d{2}[.,]\d{1,3}\s*-->/
  @voice ~r/<v(\.[^\s>]+)?\s+([^>]+)>/
  @max 60

  @doc """
  `body` with the speaker `from` called `to` in all its transcripts:
  `{:ok, body, cues}`, the number of cues changed. Refused, with nothing
  changed:

    * `{:error, :blank}` — `to` is empty once trimmed;
    * `{:error, :invalid}` — `to` is longer than #{@max} characters or holds
      `<`, `>`, `:` or a line break, any of which would read back as
      something other than a name;
    * `{:error, :unchanged}` — `to` is the name it already has;
    * `{:error, :not_found}` — no cue in a transcript is spoken by `from`.

  Naming a voice after a speaker who is already there makes them one
  speaker, which is what it means when the transcriber split one person in
  two.
  """
  def rename(body, from, to) when is_binary(body) and is_binary(from) and is_binary(to) do
    from = String.trim(from)
    to = String.trim(to)

    cond do
      to == "" -> {:error, :blank}
      String.length(to) > @max or String.match?(to, ~r/[<>:\p{Cc}]/u) -> {:error, :invalid}
      to == from -> {:error, :unchanged}
      true -> do_rename(body, from, to)
    end
  end

  @doc """
  The text of every ` ```vtt ` block in `body`, in order: the transcripts a
  page plays.
  """
  def blocks(body) when is_binary(body) do
    {blocks, _} =
      body
      |> String.split("\n")
      |> Enum.reduce({[], nil}, fn
        text, {blocks, nil} ->
          case Regex.run(@fence, text) do
            [_, fence] -> {[[] | blocks], fence}
            nil -> {blocks, nil}
          end

        text, {[block | blocks], fence} ->
          if closes?(text, fence),
            do: {[block | blocks], nil},
            else: {[[text | block] | blocks], fence}
      end)

    blocks |> Enum.reverse() |> Enum.map(&(&1 |> Enum.reverse() |> Enum.join("\n")))
  end

  def blocks(_), do: []

  defp do_rename(body, from, to) do
    {lines, %{count: count}} =
      body
      |> String.split("\n")
      |> Enum.map_reduce(%{fence: nil, first: false, count: 0}, &line(&1, &2, from, to))

    if count == 0,
      do: {:error, :not_found},
      else: {:ok, Enum.join(lines, "\n"), count}
  end

  # Outside a transcript: only its opening fence matters.
  defp line(text, %{fence: nil} = state, _from, _to) do
    case Regex.run(@fence, text) do
      [_, fence] -> {text, %{state | fence: fence}}
      nil -> {text, state}
    end
  end

  # Inside one: the fence that closes it, a cue's timing line, and the line
  # after it, which is where a cue's speaker is named.
  defp line(text, %{fence: fence} = state, from, to) do
    cond do
      closes?(text, fence) ->
        {text, %{state | fence: nil, first: false}}

      Regex.match?(@cue_time, text) ->
        {text, %{state | first: true}}

      state.first ->
        case speaker(text, from, to) do
          nil -> {text, %{state | first: false}}
          renamed -> {renamed, %{state | first: false, count: state.count + 1}}
        end

      true ->
        {text, state}
    end
  end

  defp closes?(text, fence) do
    char = String.first(fence)
    trimmed = String.trim(text)

    trimmed != "" and String.length(trimmed) >= String.length(fence) and
      trimmed == String.duplicate(char, String.length(trimmed))
  end

  # A cue's first line with its speaker renamed, or nil when `from` isn't
  # who speaks it.
  defp speaker(text, from, to) do
    case Regex.run(@voice, text, return: :index) do
      [{at, len}, class, {n_at, n_len}] ->
        if String.trim(binary_part(text, n_at, n_len)) == from do
          class = if match?({_, l} when l > 0, class), do: slice(text, class), else: ""

          binary_part(text, 0, at) <>
            "<v#{class} #{to}>" <> slice(text, {at + len, byte_size(text) - at - len})
        end

      nil ->
        prefix(text, from, to)
    end
  end

  defp slice(text, {at, len}), do: binary_part(text, at, len)

  defp prefix(text, from, to) do
    case Regex.run(~r/^(\s*)(.+?):\s+(.+)$/u, text) do
      [_, lead, name, words] -> if String.trim(name) == from, do: "#{lead}<v #{to}>#{words}"
      nil -> nil
    end
  end
end
