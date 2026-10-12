defmodule Slipdock.Wiki.FrontMatter do
  @moduledoc """
  A Markdown file's front matter, kept exactly as written (W-103 R3).

  A YAML round trip loses formatting — key order, quoting, comments, the
  blank line before the body — so this never parses and re-emits the whole
  thing. It reads the text as a run of **blocks**, one per top-level key (the
  key's line, plus the indented lines and `- items` under it), and patches
  only the blocks of keys Slipdock owns. Every other byte stays as it was.

  Two shapes travel:

    * the **header**: everything in a file before its body — the opening
      `---`, the YAML, the closing `---` and the whitespace after it. This is
      what a page stores (`Slipdock.Wiki.Page`'s `front_matter`), so the file
      it came from is `header <> body` again, exactly.
    * the **YAML**: what sits between the `---` lines. This is what the API,
      the CLI and the page's Properties block show and accept.

  Values are read just enough to map the keys Slipdock understands: a scalar
  (plain, `"double"` or `'single'` quoted), or a list (`[a, b]` or `- a`
  lines). Anything richer is somebody else's, and is left alone.
  """

  # The opening line, the YAML (absent for `---\n---`), the closing line, and
  # the blank lines between it and the body.
  @header ~r/\A(---[ \t]*\r?\n)(?:(.*?)(\r?\n))?(---[ \t]*(?:\r?\n|\z))((?:[ \t]*\r?\n)*)/s

  # A top-level key: at column 0, not a comment and not a `- item`.
  @key_line ~r/\A("(?:[^"\\]|\\.)*"|'(?:[^']|'')*'|[^\s#\-'"][^:]*?)[ \t]*:(?=[ \t]|\r?\n|\z)/

  @type block :: %{key: String.t() | nil, text: String.t()}

  ## The header ---------------------------------------------------------------

  @doc """
  Splits a file into `{header, body}`. `header` is nil when the file has no
  front matter, in which case `body` is the whole text.
  """
  @spec split(String.t()) :: {String.t() | nil, String.t()}
  def split(text) when is_binary(text) do
    case Regex.run(@header, text, return: :index) do
      [{0, len} | _] -> {binary_part(text, 0, len), binary_part(text, len, byte_size(text) - len)}
      _ -> {nil, text}
    end
  end

  @doc "The YAML inside a header — what sits between the `---` lines."
  @spec yaml(String.t() | nil) :: String.t() | nil
  def yaml(nil), do: nil

  def yaml(header) do
    case parts(header) do
      {_open, yaml, _close} -> yaml
      nil -> nil
    end
  end

  @doc """
  A header holding `yaml`, keeping `header`'s own delimiters, line endings
  and gap when there is one. Blank `yaml` with no header to keep is nil.
  """
  @spec with_yaml(String.t() | nil, String.t() | nil) :: String.t() | nil
  def with_yaml(nil, yaml) when yaml in [nil, ""], do: nil
  def with_yaml(nil, yaml), do: "---\n" <> yaml <> "\n---\n\n"

  def with_yaml(header, yaml) do
    case parts(header) do
      {open, _old, close} -> join(open, yaml || "", close)
      nil -> with_yaml(nil, yaml)
    end
  end

  # `close` carries the line break that ends the YAML when there is YAML, so
  # an empty one and a full one each put the closing `---` on a line of its own.
  defp parts(header) do
    case Regex.run(@header, header, capture: :all) do
      [_all, open, yaml, nl, close, gap] when yaml != "" or nl != "" ->
        {open, yaml, nl <> close <> gap}

      [_all, open, _yaml, _nl, close, gap] ->
        {open, "", close <> gap}

      [_all, open, "", "", close] ->
        {open, "", close}

      _ ->
        nil
    end
  end

  defp join(open, "", close), do: open <> strip_leading_break(close)

  defp join(open, yaml, close) do
    close = if String.starts_with?(close, ["\n", "\r\n"]), do: close, else: newline(open) <> close
    open <> yaml <> close
  end

  defp strip_leading_break("\r\n" <> rest), do: rest
  defp strip_leading_break("\n" <> rest), do: rest
  defp strip_leading_break(rest), do: rest

  defp newline(text), do: if(String.contains?(text, "\r\n"), do: "\r\n", else: "\n")

  @doc """
  `header` with its YAML replaced by `yaml` as a person or an agent sent it:
  `{:ok, header}`, `{:ok, nil}` for blank (no front matter at all), or
  `{:error, message}` for YAML that would end the header early.
  """
  def replace(_header, yaml) when yaml in [nil, ""], do: {:ok, nil}

  def replace(header, yaml) when is_binary(yaml) do
    yaml = String.trim_trailing(yaml, "\n")

    if valid_yaml?(yaml),
      do: {:ok, with_yaml(header, yaml)},
      else:
        {:error,
         "front_matter cannot hold a line of --- or ... on its own: that would end it early"}
  end

  def replace(_header, _yaml), do: {:error, "front_matter must be a string of YAML"}

  @doc """
  Whether `yaml` can sit between the delimiters without ending them early:
  no line of it may be `---` or `...` on its own.
  """
  def valid_yaml?(yaml) when is_binary(yaml),
    do: not Regex.match?(~r/^(---|\.\.\.)[ \t]*\r?$/m, yaml)

  ## Blocks -------------------------------------------------------------------

  @doc """
  The YAML as blocks, in order. Joining their `text` gives back the input
  exactly. Lines before the first key (a comment, say) are a block with no key.
  """
  @spec blocks(String.t()) :: [block]
  def blocks(""), do: []

  def blocks(yaml) do
    yaml
    |> lines()
    |> Enum.reduce([], fn line, acc ->
      case key_of(line) do
        nil ->
          case acc do
            [] -> [%{key: nil, text: line}]
            [last | rest] -> [%{last | text: last.text <> line} | rest]
          end

        key ->
          [%{key: key, text: line} | acc]
      end
    end)
    |> Enum.reverse()
  end

  # Lines with their endings kept, so joining them is the input.
  defp lines(text), do: Regex.split(~r/(?<=\n)/, text, trim: true)

  defp key_of(line) do
    case Regex.run(@key_line, line, capture: :all_but_first) do
      [key] -> unquote_key(String.trim(key))
      _ -> nil
    end
  end

  defp unquote_key("\"" <> _ = key), do: unquote_scalar(key)
  defp unquote_key("'" <> _ = key), do: unquote_scalar(key)
  defp unquote_key(key), do: key

  @doc "The top-level keys, in order."
  def keys(yaml), do: yaml |> blocks() |> Enum.map(& &1.key) |> Enum.reject(&is_nil/1)

  @doc "Whether `key` is set at the top level of `yaml`."
  def has_key?(yaml, key) when is_binary(yaml), do: key in keys(yaml)
  def has_key?(_, _key), do: false

  ## Reading values -----------------------------------------------------------

  @doc """
  The value of a top-level key: a string, a list of strings, or nil when it
  is absent, empty, or richer than this reads (a nested map, a block scalar).
  """
  @spec get(String.t() | nil, String.t()) :: String.t() | [String.t()] | nil
  def get(nil, _key), do: nil

  def get(yaml, key) do
    case Enum.find(blocks(yaml), &(&1.key == key)) do
      nil -> nil
      block -> value(block.text)
    end
  end

  defp value(text) do
    [first | rest] = lines(text)

    inline =
      first |> String.split(":", parts: 2) |> List.last() |> strip_comment() |> String.trim()

    cond do
      inline == "" -> block_list(rest)
      String.starts_with?(inline, "[") -> flow_list(inline)
      String.starts_with?(inline, ["|", ">", "{", "&", "*", "!"]) -> nil
      true -> unquote_scalar(inline)
    end
  end

  # `- item` lines under the key, at any indent; anything else under it means
  # a structure this does not read.
  defp block_list(lines) do
    items =
      lines
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "#")))

    cond do
      items == [] ->
        nil

      Enum.all?(items, &String.starts_with?(&1, "- ")) or Enum.all?(items, &(&1 == "-")) ->
        items
        |> Enum.map(&(&1 |> String.trim_leading("-") |> strip_comment() |> String.trim()))
        |> Enum.map(&unquote_scalar/1)
        |> Enum.reject(&(&1 == ""))

      true ->
        nil
    end
  end

  defp flow_list(inline) do
    case Regex.run(~r/\A\[(.*)\]\z/, inline, capture: :all_but_first) do
      [inner] ->
        inner
        |> split_flow()
        |> Enum.map(&(&1 |> String.trim() |> unquote_scalar()))
        |> Enum.reject(&(&1 == ""))

      _ ->
        nil
    end
  end

  # Commas outside quotes.
  defp split_flow(text) do
    Regex.scan(~r/(?:"(?:[^"\\]|\\.)*"|'(?:[^']|'')*'|[^,])+/, text)
    |> List.flatten()
  end

  # ` # comment` at the end of a plain value; a `#` inside quotes is text.
  defp strip_comment(text) do
    case Regex.run(
           ~r/\A((?:"(?:[^"\\]|\\.)*"|'(?:[^']|'')*'|[^#"'])*?)(?:\s+#.*)?\r?\n?\z/s,
           text,
           capture: :all_but_first
         ) do
      [kept] -> kept
      _ -> text
    end
  end

  defp unquote_scalar("\"" <> rest) do
    case String.split(rest, ~r/(?<!\\)"/, parts: 2) do
      [inner, _] -> inner |> String.replace("\\\"", "\"") |> String.replace("\\\\", "\\")
      _ -> rest
    end
  end

  defp unquote_scalar("'" <> rest) do
    case Regex.run(~r/\A((?:[^']|'')*)'/, rest, capture: :all_but_first) do
      [inner] -> String.replace(inner, "''", "'")
      _ -> rest
    end
  end

  defp unquote_scalar(text), do: text

  ## Patching -----------------------------------------------------------------

  @doc """
  Sets a top-level key, in place: its block is rewritten where it stands and
  every other block is left byte for byte. A key that is not there is added
  at the end. `nil` takes the key out.

  When the key already holds `value`, nothing is rewritten at all — so
  `title: "Retry policy"` stays quoted the way somebody wrote it. A boolean
  is written bare (`template: true`).

  Comment and blank lines that follow a key's value are kept, since they
  were written about what comes after as often as about it.
  """
  @spec put(String.t() | nil, String.t(), String.t() | [String.t()] | boolean | nil) :: String.t()
  def put(yaml, key, value) do
    yaml = yaml || ""
    blocks = blocks(yaml)

    case Enum.find_index(blocks, &(&1.key == key)) do
      nil when is_nil(value) ->
        yaml

      nil ->
        nl = newline(yaml)
        prefix = if yaml == "" or String.ends_with?(yaml, "\n"), do: yaml, else: yaml <> nl
        prefix <> render(key, value)

      index ->
        block = Enum.at(blocks, index)

        if value != nil and value(block.text) == comparable(value) do
          yaml
        else
          {own, trivia} = split_trivia(block.text)
          ending = Regex.run(~r/\r?\n\z/, own) |> List.wrap() |> Enum.join()
          replacement = if is_nil(value), do: trivia, else: render(key, value) <> ending <> trivia

          blocks
          |> List.replace_at(index, %{block | text: replacement})
          |> Enum.map_join(& &1.text)
          |> drop_dangling_break(yaml)
        end
    end
  end

  defp comparable(value) when is_boolean(value), do: to_string(value)
  defp comparable(value), do: value

  # Removing the last key of a header leaves the line break that separated it
  # from the one before; the YAML never ended in one, so neither does this.
  defp drop_dangling_break(new, old) do
    if String.ends_with?(old, "\n"), do: new, else: String.replace(new, ~r/\r?\n\z/, "")
  end

  # A block's own lines (the key line, and the indented or `- item` lines
  # under it), and the comment and blank lines after them.
  defp split_trivia(text) do
    [first | rest] = lines(text)

    {own, trivia} =
      Enum.split_while(rest, fn line ->
        trimmed = String.trim(line)
        (Regex.match?(~r/\A[ \t]/, line) and trimmed != "") or String.starts_with?(line, "-")
      end)

    {Enum.join([first | own]), Enum.join(trivia)}
  end

  @doc "Takes several keys out (see `put/3`)."
  def drop(yaml, keys), do: Enum.reduce(keys, yaml || "", &put(&2, &1, nil))

  defp render(key, list) when is_list(list),
    do: "#{key}: [" <> Enum.map_join(list, ", ", &scalar/1) <> "]"

  defp render(key, value) when is_boolean(value), do: "#{key}: #{value}"
  defp render(key, value), do: "#{key}: " <> scalar(to_string(value))

  # Plain when YAML would read it back as the same string; double-quoted
  # otherwise, so a title such as `Retry: why` survives.
  defp scalar(value) do
    plain? =
      value != "" and value == String.trim(value) and
        not String.contains?(value, [": ", " #", "\n", "\t"]) and
        not String.ends_with?(value, ":") and
        not String.starts_with?(value, ~w(- ? : , [ ] { } # & * ! | > ' " % @ `)) and
        String.downcase(value) not in ~w(true false yes no on off null ~)

    if plain?,
      do: value,
      else:
        "\"" <> (value |> String.replace("\\", "\\\\") |> String.replace("\"", "\\\"")) <> "\""
  end
end
