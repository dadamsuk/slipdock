defmodule Slipdock.Meetings.Transcript do
  @moduledoc """
  A meeting transcript, in whatever shape it arrived, turned into lines: who
  spoke (as the transcript labels them), from when to when, and exactly what
  they said.

  Formats:

    * `"vtt"` — WebVTT. Cue settings and ids are ignored; a `<v Name>` voice
      tag or a `Name:` prefix gives the speaker; other tags are stripped.
    * `"srt"` — SubRip. A `Name:` prefix gives the speaker.
    * `"text"` — plain text, one line per utterance, `Name: words`, with an
      optional leading `[00:01:02]` or `00:01:02` stamp. A line with no name
      is a line nobody is named for.
    * `"blocks"` — the text export Otter and Fireflies give: a header line
      (`Priya Shah  0:03`, `Priya Shah - 00:00:03`, `Priya Shah (00:03)`)
      followed by what they said, up to a blank line or the next header.
    * `"fireflies"` — Fireflies' JSON (`sentences` with `speaker_name`, `text`,
      `start_time`/`end_time` in seconds), bare or inside `data.transcript`.
    * `"otter"` — Otter's JSON (`transcripts` with `speaker`, `transcript`,
      `start_offset`/`end_offset`, in milliseconds or seconds).

  `parse/2` picks the format from a hint, the filename or the text itself.
  The words of each line are the transcript's own, trimmed of the markup
  around them and nothing else: a quote is later checked against them word
  for word (G2), so nothing here may paraphrase.
  """

  @type line :: %{
          speaker: String.t() | nil,
          start_ms: non_neg_integer() | nil,
          end_ms: non_neg_integer() | nil,
          text: String.t()
        }

  @formats ~w(vtt srt text blocks fireflies otter)

  @doc "The formats `parse/2` reads."
  def formats, do: @formats

  @doc """
  Parses a transcript. Options: `:format` (one of `formats/0`, or nil to
  detect) and `:filename` (its extension helps the detection).

  `{:ok, %{format: f, lines: [line]}}`, or `{:error, message}` naming what is
  wrong — an empty file, a format that could not be read, no words in it.
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
        format = opts[:format] || detect(content, opts[:filename])

        if format in @formats do
          with {:ok, lines} <- read(format, content) do
            case Enum.reject(lines, &(&1.text == "")) do
              [] -> {:error, "no words were found in the transcript (read as #{format})"}
              lines -> {:ok, %{format: format, lines: lines}}
            end
          end
        else
          {:error,
           "#{inspect(format)} is not a transcript format this server reads " <>
             "(it reads #{Enum.join(@formats, ", ")})"}
        end
    end
  end

  # A byte-order mark and Windows or old-Mac line endings are noise.
  defp clean(content) do
    content
    # A mark pasted together from several files can sit mid-text too.
    |> String.replace("\uFEFF", "")
    |> String.replace(~r/\r\n?/, "\n")
  end

  @doc "Which format a transcript looks like: from its extension, else its content."
  def detect(content, filename \\ nil) do
    ext = filename && filename |> Path.extname() |> String.downcase()
    trimmed = String.trim_leading(content)

    cond do
      ext == ".vtt" or String.starts_with?(trimmed, "WEBVTT") -> "vtt"
      ext == ".srt" -> "srt"
      ext == ".json" or json?(trimmed) -> json_kind(trimmed)
      srt?(trimmed) -> "srt"
      blocks?(trimmed) -> "blocks"
      true -> "text"
    end
  end

  # "[00:00:01] Priya: …" starts with a bracket too.
  defp json?(content),
    do: String.starts_with?(content, "{") or Regex.match?(~r/\A\[\s*[\{\]]/, content)

  defp json_kind(content) do
    case Jason.decode(content) do
      {:ok, %{"transcripts" => _}} -> "otter"
      {:ok, %{"data" => %{"transcript" => _}}} -> "fireflies"
      {:ok, %{"sentences" => _}} -> "fireflies"
      {:ok, list} when is_list(list) -> "fireflies"
      _ -> "fireflies"
    end
  end

  @srt_time ~r/^\d{1,2}:\d{2}:\d{2}[,.]\d{1,3}\s*-->\s*\d{1,2}:\d{2}:\d{2}[,.]\d{1,3}/m
  defp srt?(content), do: Regex.match?(~r/\A\d+\n/, content) and Regex.match?(@srt_time, content)

  # "Name  0:03" / "Name - 00:00:03" / "Name (00:03)" alone on a line.
  @block_header ~r/^(?<name>[^\n:]{1,60}?)\s*(?:\s{2,}|\s-\s|\s\()(?<ts>\d{1,2}:\d{2}(?::\d{2})?)\)?\s*$/u

  defp blocks?(content) do
    headers =
      content |> String.split("\n") |> Enum.count(&Regex.match?(@block_header, &1))

    headers >= 1 and not Regex.match?(~r/^[^\n:]{1,60}:\s+\S/m, content)
  end

  ## The formats --------------------------------------------------------------

  defp read("vtt", content) do
    {:ok,
     content
     |> String.split(~r/\n{2,}/)
     |> Enum.flat_map(&vtt_cue/1)}
  end

  defp read("srt", content) do
    {:ok,
     content
     |> String.split(~r/\n{2,}/)
     |> Enum.flat_map(&srt_cue/1)}
  end

  defp read("text", content) do
    {:ok,
     content
     |> String.split("\n")
     |> Enum.map(&String.trim/1)
     |> Enum.reject(&(&1 == ""))
     |> Enum.map(&text_line/1)
     |> ends_from_next()}
  end

  defp read("blocks", content), do: {:ok, blocks(content)}

  defp read("fireflies", content) do
    with {:ok, data} <- decode(content) do
      sentences =
        case data do
          %{"data" => %{"transcript" => %{"sentences" => s}}} -> s
          %{"transcript" => %{"sentences" => s}} -> s
          %{"sentences" => s} -> s
          s when is_list(s) -> s
          _ -> nil
        end

      if is_list(sentences) do
        {:ok,
         Enum.map(sentences, fn s ->
           %{
             speaker: blank_nil(s["speaker_name"] || s["speaker"]),
             start_ms: seconds_ms(s["start_time"]),
             end_ms: seconds_ms(s["end_time"]),
             text: words(s["raw_text"] || s["text"])
           }
         end)}
      else
        {:error, "the JSON has no `sentences` to read (expected a Fireflies export)"}
      end
    end
  end

  defp read("otter", content) do
    with {:ok, data} <- decode(content) do
      case data do
        %{"transcripts" => items} when is_list(items) ->
          speakers = otter_speakers(data["speakers"])

          {:ok,
           Enum.map(items, fn t ->
             %{
               speaker: blank_nil(speakers[t["speaker_id"]] || t["speaker"]),
               start_ms: otter_ms(t["start_offset"]),
               end_ms: otter_ms(t["end_offset"]),
               text: words(t["transcript"] || t["text"])
             }
           end)}

        _ ->
          {:error, "the JSON has no `transcripts` to read (expected an Otter export)"}
      end
    end
  end

  defp decode(content) do
    case Jason.decode(content) do
      {:ok, data} ->
        {:ok, data}

      {:error, %Jason.DecodeError{position: pos}} ->
        {:error, "the JSON is not valid (at byte #{pos})"}
    end
  end

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

  ## Speaker blocks -----------------------------------------------------------

  defp blocks(content) do
    {lines, current} =
      content
      |> String.split("\n")
      |> Enum.reduce({[], nil}, fn raw, {done, current} ->
        line = String.trim(raw)

        cond do
          match = Regex.named_captures(@block_header, line) ->
            {flush(done, current),
             %{
               speaker: String.trim(match["name"]),
               start_ms: timestamp_ms(match["ts"]),
               words: []
             }}

          line == "" ->
            {flush(done, current), current && %{current | words: []}}

          current == nil ->
            {done, %{speaker: nil, start_ms: nil, words: [line]}}

          true ->
            {done, %{current | words: current.words ++ [line]}}
        end
      end)

    lines |> flush(current) |> Enum.reverse() |> ends_from_next()
  end

  # A line's end is the next line's start, when nothing else says.
  defp ends_from_next(lines) do
    lines
    |> Enum.chunk_every(2, 1)
    |> Enum.map(fn
      [line, next] -> %{line | end_ms: line.end_ms || next.start_ms}
      [line] -> line
    end)
  end

  defp flush(done, nil), do: done
  defp flush(done, %{words: []}), do: done

  defp flush(done, %{speaker: s, start_ms: t, words: w}),
    do: [%{speaker: s, start_ms: t, end_ms: nil, text: words(Enum.join(w, " "))} | done]

  ## Small things -------------------------------------------------------------

  defp words(nil), do: ""

  defp words(text) when is_binary(text),
    do: text |> String.replace(~r/\s+/u, " ") |> String.trim()

  defp words(_), do: ""

  defp blank_nil(nil), do: nil

  defp blank_nil(value) do
    case value |> to_string() |> String.trim() do
      "" -> nil
      v -> v
    end
  end

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

  defp seconds_ms(nil), do: nil
  defp seconds_ms(n) when is_number(n), do: round(n * 1000)

  defp seconds_ms(s) when is_binary(s) do
    case Float.parse(s) do
      {n, _} -> round(n * 1000)
      :error -> nil
    end
  end

  # Otter's offsets: whole milliseconds, or seconds with a fraction.
  defp otter_ms(n) when is_integer(n), do: n
  defp otter_ms(n) when is_float(n), do: round(n * 1000)
  defp otter_ms(_), do: nil

  defp otter_speakers(list) when is_list(list),
    do: Map.new(list, &{&1["id"], &1["name"]})

  defp otter_speakers(_), do: %{}
end
