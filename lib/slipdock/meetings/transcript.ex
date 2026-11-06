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
    * `"chat"` — a conversation as `Name: words` turns (#1073). A turn runs
      on, line after line, up to the next label; a label inside a ``` code
      fence is part of the turn, not a new one; words before the first label
      are a line nobody is named for.
    * `"claude-export"` — claude.ai's export: `conversations.json` (a list)
      or one conversation, each with `chat_messages` of `sender` and `text`.
    * `"chatgpt-export"` — ChatGPT's export: a conversation's `mapping`
      tree, read along the branch the conversation was left on
      (`current_node` back to the root), so abandoned edits are not read.

  An export holding several conversations is read for the one named by
  `:conversation` (its id or title). In a chat, the person is `:person`
  (default `"User"`) and the assistant `"Claude"` or `"ChatGPT"`.

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

  @formats ~w(vtt srt text blocks fireflies otter chat claude-export chatgpt-export)

  @doc "The formats `parse/2` reads."
  def formats, do: @formats

  @doc """
  Parses a transcript. Options: `:format` (one of `formats/0`, or nil to
  detect), `:filename` (its extension helps the detection), and for the chat
  exports `:conversation` (id or title) and `:person` (the human's name).

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
          with {:ok, lines} <- read(format, content, opts) do
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
      chat?(trimmed) -> "chat"
      true -> "text"
    end
  end

  # "[00:00:01] Priya: …" starts with a bracket too.
  defp json?(content),
    do: String.starts_with?(content, "{") or Regex.match?(~r/\A\[\s*[\{\]]/, content)

  defp json_kind(content) do
    case Jason.decode(content) do
      {:ok, %{"chat_messages" => _}} -> "claude-export"
      {:ok, %{"mapping" => _}} -> "chatgpt-export"
      {:ok, [%{"chat_messages" => _} | _]} -> "claude-export"
      {:ok, [%{"mapping" => _} | _]} -> "chatgpt-export"
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

  # A conversation, not a meeting: it has a code fence, or someone in it is
  # labelled the way chat apps label the two sides. Timestamps say meeting.
  @chat_labels ~w(user human you me assistant ai claude chatgpt gpt)

  defp chat?(content) do
    labels =
      content
      |> String.split("\n")
      |> Enum.flat_map(fn line ->
        case chat_label(line) do
          {name, _} -> [String.downcase(name)]
          nil -> []
        end
      end)

    labels != [] and not Regex.match?(~r/^\[?\d{1,2}:\d{2}/m, content) and
      (Regex.match?(~r/^\s*```/m, content) or Enum.any?(labels, &(&1 in @chat_labels)))
  end

  ## The formats --------------------------------------------------------------

  defp read("chat", content, _opts), do: {:ok, chat(content)}

  defp read("claude-export", content, opts) do
    with {:ok, data} <- decode(content, "a Claude export"),
         {:ok, convo} <- conversation(data, "chat_messages", "a Claude export", opts) do
      person = opts[:person] || "User"

      {:ok,
       convo["chat_messages"]
       |> List.wrap()
       |> Enum.map(fn m ->
         speaker = if m["sender"] == "human", do: person, else: "Claude"
         chat_line(speaker, claude_text(m))
       end)}
    end
  end

  defp read("chatgpt-export", content, opts) do
    with {:ok, data} <- decode(content, "a ChatGPT export"),
         {:ok, convo} <- conversation(data, "mapping", "a ChatGPT export", opts) do
      person = opts[:person] || "User"

      {:ok,
       convo
       |> current_branch()
       |> Enum.flat_map(fn node ->
         case node["message"] do
           %{"author" => %{"role" => role}} = m when role in ["user", "assistant"] ->
             if get_in(m, ["metadata", "is_visually_hidden_from_conversation"]) do
               []
             else
               speaker = if role == "user", do: person, else: "ChatGPT"
               [chat_line(speaker, chatgpt_text(m["content"]))]
             end

           _ ->
             []
         end
       end)}
    end
  end

  defp read(format, content, _opts), do: read(format, content)

  # The formats the wiki reads too live in `Slipdock.Transcript`.
  defp read(format, content) when format in ~w(vtt srt text),
    do: {:ok, Slipdock.Transcript.lines(content, format)}

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

  defp decode(content, expected \\ nil) do
    case Jason.decode(content) do
      {:ok, data} ->
        {:ok, data}

      {:error, %Jason.DecodeError{position: pos}} when expected == nil ->
        {:error, "the JSON is not valid (at byte #{pos})"}

      {:error, %Jason.DecodeError{position: pos}} ->
        {:error, "the JSON is not valid (at byte #{pos}; expected #{expected})"}
    end
  end

  ## Chats --------------------------------------------------------------------

  # "Name: words", "**Name:** words", or "Name:" alone with the words below.
  @chat_label ~r/^\s*(?:\*\*)?([\p{L}][\p{L}\p{M}0-9 .'’_-]{0,30}?)(?:\*\*)?:(?:\*\*)?(?:\s+(.*))?$/u

  defp chat_label(line) do
    case Regex.run(@chat_label, line) do
      [_, name | rest] ->
        if length(String.split(name)) <= 3, do: {String.trim(name), List.first(rest) || ""}

      nil ->
        nil
    end
  end

  defp chat(content) do
    lines = String.split(content, "\n")
    known = chat_speakers(lines)

    {turns, current, _fence} =
      Enum.reduce(lines, {[], nil, false}, fn line, {done, current, fence} ->
        cond do
          Regex.match?(~r/^\s*```/, line) ->
            {done, add_words(current, line), not fence}

          fence ->
            {done, add_words(current, line), fence}

          (label = chat_label(line)) && elem(label, 0) in known ->
            {name, words} = label
            {flush(done, current), %{speaker: name, start_ms: nil, words: [words]}, fence}

          true ->
            {done, add_words(current, line), fence}
        end
      end)

    turns |> flush(current) |> Enum.reverse()
  end

  # Who speaks: everyone labelled outside a code fence the way chat apps
  # label the sides, or labelled twice or more. One "Note:" in the middle of
  # an answer is part of the answer, not a third speaker. When nobody
  # qualifies, every label counts.
  defp chat_speakers(lines) do
    {labels, _} =
      Enum.reduce(lines, {[], false}, fn line, {acc, fence} ->
        cond do
          Regex.match?(~r/^\s*```/, line) -> {acc, not fence}
          fence -> {acc, fence}
          label = chat_label(line) -> {[elem(label, 0) | acc], fence}
          true -> {acc, fence}
        end
      end)

    freq = Enum.frequencies(labels)

    known =
      for {name, n} <- freq, n >= 2 or String.downcase(name) in @chat_labels, do: name

    if known == [], do: Map.keys(freq), else: known
  end

  defp add_words(nil, line), do: %{speaker: nil, start_ms: nil, words: [line]}
  defp add_words(current, line), do: %{current | words: current.words ++ [line]}

  defp chat_line(speaker, text),
    do: %{speaker: speaker, start_ms: nil, end_ms: nil, text: words(text)}

  # The conversation to read: the export itself, or the one asked for from a
  # list of them (the only one, when there is one).
  defp conversation(data, key, expected, opts) do
    convos =
      case data do
        %{^key => _} -> [data]
        list when is_list(list) -> Enum.filter(list, &(is_map(&1) and Map.has_key?(&1, key)))
        _ -> []
      end

    wanted = opts[:conversation] && to_string(opts[:conversation])

    case {convos, wanted} do
      {[], _} ->
        {:error, "the JSON has no `#{key}` to read (expected #{expected})"}

      {[one], nil} ->
        {:ok, one}

      {many, nil} ->
        {:error,
         "the export holds #{length(many)} conversations; choose one by id or title " <>
           "(#{many |> Enum.take(5) |> Enum.map_join(", ", &inspect(convo_title(&1)))}" <>
           if(length(many) > 5, do: ", …)", else: ")")}

      {many, wanted} ->
        case Enum.find(many, &(wanted in [&1["uuid"], &1["id"], &1["conversation_id"]])) ||
               Enum.find(many, &(convo_title(&1) == wanted)) do
          nil -> {:error, "no conversation in the export has the id or title #{inspect(wanted)}"}
          convo -> {:ok, convo}
        end
    end
  end

  defp convo_title(convo), do: convo["name"] || convo["title"] || convo["uuid"] || convo["id"]

  defp claude_text(%{"text" => text}) when is_binary(text) and text != "", do: text

  defp claude_text(%{"content" => content}) when is_list(content) do
    content
    |> Enum.filter(&(is_map(&1) and &1["type"] == "text"))
    |> Enum.map_join("\n", &(&1["text"] || ""))
  end

  defp claude_text(_), do: ""

  defp chatgpt_text(%{"parts" => parts}) when is_list(parts),
    do: parts |> Enum.filter(&is_binary/1) |> Enum.join("\n")

  defp chatgpt_text(%{"text" => text}) when is_binary(text), do: text
  defp chatgpt_text(_), do: ""

  # The branch the conversation was left on: from `current_node` back up to
  # the root. With no current node, from the root down along the latest
  # child at each fork.
  defp current_branch(%{"mapping" => mapping} = convo) when is_map(mapping) do
    case mapping[convo["current_node"]] do
      nil ->
        root = Enum.find(Map.values(mapping), &is_nil(&1["parent"]))
        down(mapping, root, MapSet.new())

      node ->
        up(mapping, node, [], MapSet.new())
    end
  end

  defp current_branch(_), do: []

  # A cycle in a broken export stops the walk rather than looping.
  defp up(_mapping, nil, acc, _seen), do: acc

  defp up(mapping, node, acc, seen) do
    if MapSet.member?(seen, node["id"]),
      do: acc,
      else: up(mapping, mapping[node["parent"]], [node | acc], MapSet.put(seen, node["id"]))
  end

  defp down(_mapping, nil, _seen), do: []

  defp down(mapping, node, seen) do
    if MapSet.member?(seen, node["id"]) do
      []
    else
      next = node["children"] |> List.wrap() |> List.last()
      [node | down(mapping, next && mapping[next], MapSet.put(seen, node["id"]))]
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

    lines |> flush(current) |> Enum.reverse() |> Slipdock.Transcript.ends_from_next()
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

  @doc "`01:02:03.456`, `02:03,4`, `2:03` → milliseconds."
  defdelegate timestamp_ms(ts), to: Slipdock.Transcript

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
