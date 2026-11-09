defmodule Slipdock.Transcript do
  @moduledoc """
  A transcript turned into lines: who spoke (as the transcript labels them),
  from when to when, and exactly what they said. The wiki's transcript view
  (`Slipdock.Wiki.Viewer`), its speaker renaming
  (`Slipdock.Wiki.TranscriptSpeakers`) and voiceprints
  (`Slipdock.Transcription.Voiceprints`) read them.

  Formats:

    * `"vtt"` — WebVTT. Cue settings and ids are ignored; a `<v Name>` voice
      tag or a `Name:` prefix gives the speaker; other tags are stripped.
    * `"srt"` — SubRip. A `Name:` prefix gives the speaker.
    * `"text"` — plain text, one line per utterance, `Name: words`, with an
      optional leading `[00:01:02]` or `00:01:02` stamp. A line with no name
      is a line nobody is named for.

  The words of each line are the transcript's own, trimmed of the markup
  around them and nothing else.
  """

  @type line :: %{
          speaker: String.t() | nil,
          start_ms: non_neg_integer() | nil,
          end_ms: non_neg_integer() | nil,
          text: String.t()
        }

  @formats ~w(vtt srt text)

  @doc "The formats `parse/2` reads."
  def formats, do: @formats

  @doc """
  Parses a transcript. Options: `:format` (one of `formats/0`, or nil to
  detect) and `:filename` (its extension helps the detection).

  `{:ok, %{format: f, lines: [line]}}`, or `{:error, message}` naming what is
  wrong: an empty file, a format it doesn't read, no words in it.
  """
  @spec parse(binary(), keyword()) ::
          {:ok, %{format: String.t(), lines: [line]}} | {:error, String.t()}
  def parse(content, opts \\ []) when is_binary(content) do
    content = clean(content)

    cond do
      not String.valid?(content) ->
        {:error, "the transcript is not text (it should be UTF-8)"}

      String.trim(content) == "" ->
        {:error, "the transcript is empty"}

      true ->
        read(content, opts[:format] || detect(content, opts[:filename]))
    end
  end

  defp read(content, format) when format in @formats do
    case content |> lines(format) |> Enum.reject(&(&1.text == "")) do
      [] -> {:error, "no words were found in the transcript (read as #{format})"}
      lines -> {:ok, %{format: format, lines: lines}}
    end
  end

  defp read(_content, format) do
    {:error,
     "#{inspect(format)} is not a transcript format this server reads " <>
       "(it reads #{Enum.join(@formats, ", ")})"}
  end

  # A byte-order mark and Windows or old-Mac line endings are noise.
  defp clean(content) do
    content
    # A mark pasted together from several files can sit mid-text too.
    |> String.replace("﻿", "")
    |> String.replace(~r/\r\n?/, "\n")
  end

  @srt_time ~r/^\d{1,2}:\d{2}:\d{2}[,.]\d{1,3}\s*-->\s*\d{1,2}:\d{2}:\d{2}[,.]\d{1,3}/m

  @doc "Which of `formats/0` a transcript looks like: from its extension, else its content."
  def detect(content, filename \\ nil) do
    ext = filename && filename |> Path.extname() |> String.downcase()
    trimmed = String.trim_leading(content)

    cond do
      ext == ".vtt" or String.starts_with?(trimmed, "WEBVTT") -> "vtt"
      ext == ".srt" -> "srt"
      Regex.match?(~r/\A\d+\n/, trimmed) and Regex.match?(@srt_time, trimmed) -> "srt"
      true -> "text"
    end
  end

  @doc false
  # The lines of an already cleaned transcript in one of `formats/0`, empty
  # ones included.
  def lines(content, "vtt"),
    do: content |> String.split(~r/\n{2,}/) |> Enum.flat_map(&vtt_cue/1)

  def lines(content, "srt"),
    do: content |> String.split(~r/\n{2,}/) |> Enum.flat_map(&srt_cue/1)

  def lines(content, "text") do
    content
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&text_line/1)
    |> ends_from_next()
  end

  ## Speakers -----------------------------------------------------------------

  @doc """
  Whether a transcript's speaker label is a person's name ("Priya Nair",
  "Ryan") rather than a placeholder for a voice ("Speaker 2", "Unknown-3",
  "SPEAKER_00", "S1").
  """
  def person_label?(label) when is_binary(label) do
    label = String.trim(label)

    label != "" and String.match?(label, ~r/\p{L}/u) and
      not String.match?(
        label,
        ~r/^(speaker|unknown|voice|spk|participant|guest)\b|^(speaker|spk|s)[\s_-]*\d+$/iu
      )
  end

  def person_label?(_label), do: false

  ## Cues ---------------------------------------------------------------------

  @cue_time ~r/^(?<s>(?:\d{1,2}:)?\d{1,2}:\d{2}[.,]\d{1,3})\s*-->\s*(?<e>(?:\d{1,2}:)?\d{1,2}:\d{2}[.,]\d{1,3})/

  defp vtt_cue(block) do
    lines = String.split(block, "\n")

    case Enum.split_while(lines, &(not Regex.match?(@cue_time, &1))) do
      {_, []} ->
        # The header, a NOTE, a STYLE block: no timing, no words.
        []

      {_id, [timing | text]} ->
        %{"s" => s, "e" => e} = Regex.named_captures(@cue_time, timing)
        text = Enum.join(text, " ")

        {speaker, text} =
          case Regex.run(~r/<v(?:\.[^\s>]+)?\s+([^>]+)>/, text) do
            [_, name] -> {String.trim(name), text}
            nil -> {nil, text}
          end

        text = text |> String.replace(~r/<[^>]+>/, "") |> unescape() |> words()
        cue_line(speaker, timestamp_ms(s), timestamp_ms(e), text)
    end
  end

  defp srt_cue(block) do
    lines = block |> String.split("\n") |> Enum.reject(&(&1 == ""))

    case Enum.split_while(lines, &(not Regex.match?(@cue_time, &1))) do
      {_, []} ->
        []

      {_index, [timing | text]} ->
        %{"s" => s, "e" => e} = Regex.named_captures(@cue_time, timing)
        text = text |> Enum.join(" ") |> String.replace(~r/<[^>]+>/, "") |> words()
        cue_line(nil, timestamp_ms(s), timestamp_ms(e), text)
    end
  end

  # A cue whose words start "Name:" names its speaker that way.
  defp cue_line(nil, start_ms, end_ms, text) do
    {speaker, text} = split_name(text)
    [%{speaker: speaker, start_ms: start_ms, end_ms: end_ms, text: text}]
  end

  defp cue_line(speaker, start_ms, end_ms, text),
    do: [%{speaker: speaker, start_ms: start_ms, end_ms: end_ms, text: text}]

  ## Plain text ---------------------------------------------------------------

  @stamp ~r/^\[?(?<ts>(?:\d{1,2}:)?\d{1,2}:\d{2}(?:[.,]\d{1,3})?)\]?\s+/

  defp text_line(line) do
    {start_ms, rest} =
      case Regex.named_captures(@stamp, line) do
        %{"ts" => ts} -> {timestamp_ms(ts), Regex.replace(@stamp, line, "", global: false)}
        nil -> {nil, line}
      end

    {speaker, text} = split_name(rest)
    %{speaker: speaker, start_ms: start_ms, end_ms: nil, text: words(text)}
  end

  # "Priya Shah: words" — a name is short and has no sentence punctuation in it,
  # so "Note: the date moved" with a one-word lead is still read as a name, but
  # "We agreed on this: ship it" is not.
  defp split_name(text) do
    case Regex.run(~r/^([\p{L}][\p{L}\p{M}0-9 .'’()_-]{0,40}?):\s+(.+)$/u, text) do
      [_, name, rest] ->
        if length(String.split(name)) <= 4,
          do: {String.trim(name), words(rest)},
          else: {nil, words(text)}

      nil ->
        {nil, words(text)}
    end
  end

  @doc false
  # A line's end is the next line's start, when nothing else says.
  def ends_from_next(lines) do
    lines
    |> Enum.chunk_every(2, 1)
    |> Enum.map(fn
      [line, next] -> %{line | end_ms: line.end_ms || next.start_ms}
      [line] -> line
    end)
  end

  ## Small things -------------------------------------------------------------

  defp words(text), do: text |> String.replace(~r/\s+/u, " ") |> String.trim()

  defp unescape(text) do
    text
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&nbsp;", " ")
    |> String.replace("&amp;", "&")
  end

  @doc "`01:02:03.456`, `02:03,4`, `2:03` → milliseconds."
  def timestamp_ms(ts) do
    {clock, frac} =
      case String.split(ts, ~r/[.,]/, parts: 2) do
        [clock, frac] -> {clock, frac}
        [clock] -> {clock, "0"}
      end

    seconds =
      clock
      |> String.split(":")
      |> Enum.map(&String.to_integer/1)
      |> Enum.reduce(0, fn part, acc -> acc * 60 + part end)

    frac_ms = frac |> String.pad_trailing(3, "0") |> String.slice(0, 3) |> String.to_integer()
    seconds * 1000 + frac_ms
  end
end
