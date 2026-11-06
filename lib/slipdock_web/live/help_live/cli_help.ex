defmodule SlipdockWeb.HelpLive.CLIHelp do
  @moduledoc """
  The CLI's help (`cli/help.txt`, the file `slipdock help` prints), read at
  compile time and parsed into groups and commands for the web's command
  reference (`SlipdockWeb.HelpLive.CLIReference`). Change the help and this
  recompiles, so the page and the CLI can't disagree.

  The help's layout is what it is parsed by:

    * a group starts with a line in capitals at the left edge (`READ`,
      `FIND ANYTHING  (semantic: …`); a parenthesis it opens runs on until it
      closes, and is the group's note;
    * an entry starts with a line indented two spaces or less, and every line
      indented further belongs to it;
    * an entry's first line is the command, then its description (see
      `split_line/2`); lines indented to about where it starts (or column 20)
      carry the description on, `[…` lines carry the command on,
      and anything else (options, examples) is kept verbatim as its details.

  `USAGE` is shown in the page's header rather than as a group.
  """

  @help_path Path.expand("../../../../cli/help.txt", __DIR__)
  @external_resource @help_path
  @help File.read!(@help_path)

  @doc "The help text exactly as `slipdock help` prints it (less the final newline)."
  def text, do: @help

  @doc """
  The help parsed: `%{title: line, usage: [lines], groups: [group]}`, each
  group `%{id, name, title, note, entries}` and each entry `%{usage, desc,
  details}`.
  """
  def parse(text) do
    [title | lines] = String.split(text, "\n")
    groups = lines |> chunk_groups() |> Enum.map(&group/1)
    {usage, groups} = Enum.split_with(groups, &(&1.name == "USAGE"))

    %{
      title: title,
      usage: Enum.flat_map(usage, fn g -> Enum.map(g.entries, & &1.usage) end),
      groups: groups
    }
  end

  @doc "The entries of `groups` whose command matches `query` (case-insensitive); empty groups go."
  def filter(groups, query) do
    case query |> to_string() |> String.trim() |> String.downcase() do
      "" ->
        groups

      q ->
        groups
        |> Enum.map(fn g ->
          %{g | entries: Enum.filter(g.entries, &(&1.usage |> String.downcase() =~ q))}
        end)
        |> Enum.reject(&(&1.entries == []))
    end
  end

  @doc """
  A command's usage in the pieces it should wrap between: words, and each
  `[ … ]` or quoted part whole, so a narrow screen breaks between options
  rather than inside one.
  """
  def chunks(usage) do
    usage
    |> String.graphemes()
    |> Enum.reduce({[], "", 0, false}, fn
      " ", {done, cur, 0, false} ->
        {[cur | done], "", 0, false}

      c, {done, cur, depth, quoted} ->
        {done, cur <> c, depth + depth_change(c), quote_change(c, quoted)}
    end)
    |> then(fn {done, cur, _, _} -> Enum.reverse([cur | done]) end)
    |> Enum.reject(&(&1 == ""))
  end

  defp depth_change("["), do: 1
  defp depth_change("]"), do: -1
  defp depth_change(_), do: 0

  defp quote_change(~s("), quoted), do: not quoted
  defp quote_change(_, quoted), do: quoted

  # ── Parsing ───────────────────────────────────────────────────────────────

  @heading ~r/^([A-Z][A-Z]+(?: [A-Z]+)*)(?=\s|$)(.*)$/

  defp chunk_groups(lines) do
    lines
    |> Enum.reduce([], fn line, acc ->
      case {Regex.run(@heading, line), acc} do
        {[_, name, rest], _} -> [{name, [String.trim(rest)], []} | acc]
        {nil, []} -> acc
        {nil, [{name, note, body} | done]} -> [{name, note, [line | body]} | done]
      end
    end)
    |> Enum.reverse()
    |> Enum.map(fn {name, note, body} -> {name, note, Enum.reverse(body)} end)
  end

  defp group({name, [note], body}) do
    {note_lines, body} = note_rest(note, body)

    %{
      id: "cli-" <> (name |> String.downcase() |> String.replace(" ", "-")),
      name: name,
      title: String.capitalize(name),
      note: Enum.join([note | note_lines], " ") |> String.trim(),
      entries: entries(body)
    }
  end

  # A note whose parenthesis is still open takes lines until it closes.
  defp note_rest(note, body) do
    if open_parens(note) > 0, do: take_note(body, open_parens(note), []), else: {[], body}
  end

  defp take_note([line | rest], open, acc) when open > 0,
    do: take_note(rest, open + open_parens(line), [String.trim(line) | acc])

  defp take_note(rest, _open, acc), do: {Enum.reverse(acc), rest}

  defp open_parens(s),
    do: length(String.split(s, "(")) - length(String.split(s, ")"))

  defp entries(body) do
    body
    |> Enum.reject(&(String.trim(&1) == ""))
    |> Enum.chunk_while(
      [],
      fn line, acc ->
        if indent(line) <= 2 and acc != [],
          do: {:cont, Enum.reverse(acc), [line]},
          else: {:cont, [line | acc]}
      end,
      fn
        [] -> {:cont, []}
        acc -> {:cont, Enum.reverse(acc), []}
      end
    )
    |> Enum.map(&entry/1)
  end

  defp entry([first | more]) do
    col = desc_column(more)
    {usage, desc, desc_at} = split_line(first, col)
    start = %{usage: usage, desc: List.wrap(desc), details: []}
    # A description carries on from about where it started, or column 20.
    carry_on = min(desc_at - 2, 20)

    entry =
      Enum.reduce(more, start, fn line, e ->
        trimmed = String.trim(line)

        cond do
          e.details == [] and e.desc == [] and String.starts_with?(trimmed, "[") ->
            {usage, desc, _} = split_line(line, col)
            %{e | usage: e.usage <> " " <> usage, desc: List.wrap(desc)}

          e.details == [] and indent(line) >= carry_on and not String.starts_with?(trimmed, "-") ->
            %{e | desc: e.desc ++ [trimmed]}

          true ->
            %{e | details: e.details ++ [line]}
        end
      end)

    %{entry | desc: Enum.join(entry.desc, " "), details: dedent(entry.details)}
  end

  # Where the entry's description runs: the indent of its first carried-on
  # line, else the help's usual column.
  defp desc_column(more) do
    Enum.find_value(more, 38, fn line ->
      trimmed = String.trim(line)
      if indent(line) >= 30 and not String.starts_with?(trimmed, ["-", "["]), do: indent(line)
    end)
  end

  # A line split into the command and its description, and the column the
  # description starts at (22 when there is none). They are split at a gap
  # (three spaces, or two past column 20), or, where a long command runs up
  # to its description with one space, at the first word in the description
  # column that starts in lower case outside any [ ] or quotes. A `|` beside
  # a gap joins two commands rather than starting a description.
  defp split_line(line, col) do
    lead = indent(line)

    words =
      Regex.scan(~r/\S+/u, line, return: :index)
      |> Enum.map(fn [{at, len}] ->
        word = binary_part(line, at, len)
        start = String.length(binary_part(line, 0, at))
        {start, start + String.length(word), word}
      end)

    words
    |> Enum.zip([nil | words])
    |> Enum.reduce_while({0, false}, fn
      {_word, nil}, state ->
        {:cont, next_state(state, hd(words))}

      {{start, _, word} = w, {_, prev_end, prev}}, {depth, quoted} = state ->
        outside? = depth == 0 and not quoted and not Enum.member?([word, prev], "|")

        if outside? and splits_here?(start - prev_end, start, word, lead, col),
          do: {:halt, {:split, prev_end, start}},
          else: {:cont, next_state(state, w)}
    end)
    |> case do
      {:split, usage_end, desc_start} ->
        {String.slice(line, lead, usage_end - lead), String.slice(line, desc_start..-1//1),
         desc_start}

      _ ->
        {String.trim(line), nil, 22}
    end
  end

  # A gap of three, two past column 20, or one before a lower-case word in
  # the description column.
  defp splits_here?(gap, _start, _word, _lead, _col) when gap >= 3, do: true
  defp splits_here?(2, start, _word, lead, _col), do: start - lead >= 20
  defp splits_here?(1, start, word, _lead, col), do: start >= col - 2 and word =~ ~r/^[a-z]/
  defp splits_here?(_gap, _start, _word, _lead, _col), do: false

  defp next_state({depth, quoted}, {_, _, word}) do
    opens = word |> String.graphemes() |> Enum.count(&(&1 == "["))
    closes = word |> String.graphemes() |> Enum.count(&(&1 == "]"))
    quotes = word |> String.graphemes() |> Enum.count(&(&1 == ~s(")))
    {depth + opens - closes, if(rem(quotes, 2) == 1, do: not quoted, else: quoted)}
  end

  defp indent(line), do: String.length(line) - String.length(String.trim_leading(line))

  defp dedent([]), do: []

  defp dedent(lines) do
    cut = lines |> Enum.map(&indent/1) |> Enum.min()
    Enum.map(lines, &String.slice(&1, cut..-1//1))
  end
end
