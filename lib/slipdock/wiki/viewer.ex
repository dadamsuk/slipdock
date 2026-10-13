defmodule Slipdock.Wiki.Viewer do
  @moduledoc """
  What the file viewer (`SlipdockWeb.FileLive`) shows a wiki file as, and
  the reading that takes: images and PDFs are the browser's to draw, so
  only their kind is decided here, and HTML too, drawn in a sandbox; JSON, CSV and plain text are read on the
  server and handed over as a tree, a table or the text.

  Text is read only up to `max_text/0` bytes, so a 200 MB log is a
  "download it" rather than a page that never arrives, and a table or a
  tree is cut short at a count a browser can still draw.
  """

  alias Slipdock.Wiki.{Files, WikiFile}

  @max_text 2_000_000
  @max_rows 1_000
  @max_nodes 5_000

  def max_text, do: @max_text
  def max_rows, do: @max_rows

  @doc """
  Which viewer a file gets: `:image`, `:svg`, `:pdf`, `:html`, `:json`, `:csv`,
  `:tsv`, `:text` or `:none`. Decided by the name, which is what a synced
  vault reliably has.
  """
  def kind(%WikiFile{} = file) do
    cond do
      WikiFile.image?(file) -> :image
      true -> kind_of_name(file.name)
    end
  end

  defp kind_of_name(name) do
    case name |> to_string() |> Path.extname() |> String.downcase() do
      ".svg" -> :svg
      ".pdf" -> :pdf
      ext when ext in ~w(.html .htm) -> :html
      ext when ext in ~w(.json .geojson .jsonl .ndjson) -> :json
      ".csv" -> :csv
      ".tsv" -> :tsv
      ext when ext in ~w(.txt .log .md .yaml .yml .toml .ini .xml) -> :text
      _ -> :none
    end
  end

  @doc """
  The file's bytes as text, for the kinds read on the server:
  `{:ok, text}`, `{:error, :too_large}`, `{:error, :not_text}` (not UTF-8)
  or `{:error, :missing}`.
  """
  def read(%WikiFile{} = file) do
    cond do
      file.size > @max_text -> {:error, :too_large}
      true -> read_text(Files.disk_path(file))
    end
  end

  defp read_text(path) do
    case File.read(path) do
      {:ok, bytes} when byte_size(bytes) > @max_text ->
        {:error, :too_large}

      {:ok, bytes} ->
        if String.valid?(bytes), do: {:ok, strip_bom(bytes)}, else: {:error, :not_text}

      {:error, _} ->
        {:error, :missing}
    end
  end

  defp strip_bom(<<0xEF, 0xBB, 0xBF, rest::binary>>), do: rest
  defp strip_bom(text), do: text

  ## JSON ---------------------------------------------------------------------

  @doc """
  JSON as a tree for the viewer: `{:ok, tree, pretty}` where `tree` is
  `nil` when the document has more than #{@max_nodes} values (too many to
  fold open one by one, so it is shown as `pretty` text alone), or
  `{:error, message}` saying where it stopped making sense.

  A tree node is `{:object, [{key, node}]}`, `{:array, [node]}` or
  `{:value, json_text}`; object keys keep the order the file has them in.
  A JSON Lines file (`.jsonl`, `.ndjson`) is read a line at a time and
  shown as an array of its lines.
  """
  def json(text, name \\ "") do
    if String.downcase(Path.extname(to_string(name))) in ~w(.jsonl .ndjson),
      do: json_lines(text),
      else: json_document(text)
  end

  defp json_document(text) do
    case Jason.decode(text, objects: :ordered_objects) do
      {:ok, value} -> {:ok, tree(value), pretty(value)}
      {:error, %Jason.DecodeError{} = e} -> {:error, json_error(text, e)}
    end
  end

  defp json_lines(text) do
    text
    |> String.split(["\r\n", "\n"])
    |> Enum.with_index(1)
    |> Enum.reject(fn {line, _} -> String.trim(line) == "" end)
    |> Enum.reduce_while([], fn {line, n}, acc ->
      case Jason.decode(line, objects: :ordered_objects) do
        {:ok, value} -> {:cont, [value | acc]}
        {:error, _} -> {:halt, {:error, "Line #{n} isn't JSON."}}
      end
    end)
    |> case do
      {:error, _} = error ->
        error

      values ->
        values = Enum.reverse(values)
        {:ok, tree(values), Enum.map_join(values, "\n", &Jason.encode!/1)}
    end
  end

  defp pretty(value), do: Jason.encode!(value, pretty: true)

  defp tree(value) do
    if count(value, 0) > @max_nodes, do: nil, else: to_node(value)
  end

  defp count(_value, n) when n > @max_nodes, do: n

  defp count(%Jason.OrderedObject{values: kvs}, n),
    do: Enum.reduce(kvs, n + 1, fn {_, v}, n -> count(v, n) end)

  defp count(list, n) when is_list(list), do: Enum.reduce(list, n + 1, &count/2)
  defp count(_value, n), do: n + 1

  defp to_node(%Jason.OrderedObject{values: kvs}),
    do: {:object, Enum.map(kvs, fn {k, v} -> {k, to_node(v)} end)}

  defp to_node(list) when is_list(list), do: {:array, Enum.map(list, &to_node/1)}
  defp to_node(value), do: {:value, Jason.encode!(value)}

  defp json_error(text, %Jason.DecodeError{position: position}) do
    before = binary_part(text, 0, min(position, byte_size(text)))
    lines = String.split(before, "\n")

    "This isn't valid JSON: it stops making sense at line #{length(lines)}, column #{String.length(List.last(lines)) + 1}."
  end

  ## CSV ----------------------------------------------------------------------

  @doc """
  Comma- (or, with `?\\t`, tab-) separated text as `%{header, rows, total}`:
  the first row as the header, at most #{@max_rows} rows after it, and how
  many there were in all. Quoted fields may hold the separator, doubled
  quotes and line breaks (RFC 4180); a ragged row is padded to the widest.
  """
  def csv(text, separator \\ ?,) do
    case text |> parse_csv(separator) |> drop_leading_blank() do
      [] ->
        %{header: [], rows: [], total: 0}

      [header | rows] ->
        rows = Enum.reject(rows, &(&1 == [""]))

        width = Enum.max(Enum.map([header | rows], &length/1))
        pad = fn row -> row ++ List.duplicate("", width - length(row)) end

        %{
          header: pad.(header),
          rows: rows |> Enum.take(@max_rows) |> Enum.map(pad),
          total: length(rows)
        }
    end
  end

  defp drop_leading_blank([[""] | rows]), do: drop_leading_blank(rows)
  defp drop_leading_blank(rows), do: rows

  defp parse_csv(text, sep), do: parse_field(text, sep, [], [], "")

  # parse_field(rest, sep, rows, row, field)
  defp parse_field("", _sep, rows, [], ""), do: Enum.reverse(rows)

  defp parse_field("", _sep, rows, row, field),
    do: Enum.reverse([Enum.reverse([field | row]) | rows])

  defp parse_field(<<?", rest::binary>>, sep, rows, row, ""),
    do: parse_quoted(rest, sep, rows, row, "")

  defp parse_field(<<c, rest::binary>>, sep, rows, row, field) when c == sep,
    do: parse_field(rest, sep, rows, [field | row], "")

  defp parse_field(<<"\r\n", rest::binary>>, sep, rows, row, field),
    do: end_row(rest, sep, rows, row, field)

  defp parse_field(<<"\n", rest::binary>>, sep, rows, row, field),
    do: end_row(rest, sep, rows, row, field)

  defp parse_field(<<c::utf8, rest::binary>>, sep, rows, row, field),
    do: parse_field(rest, sep, rows, row, field <> <<c::utf8>>)

  defp end_row(rest, sep, rows, row, field),
    do: parse_field(rest, sep, [Enum.reverse([field | row]) | rows], [], "")

  defp parse_quoted(<<?", ?", rest::binary>>, sep, rows, row, field),
    do: parse_quoted(rest, sep, rows, row, field <> "\"")

  defp parse_quoted(<<?", rest::binary>>, sep, rows, row, field),
    do: after_quote(rest, sep, rows, row, field)

  defp parse_quoted(<<c::utf8, rest::binary>>, sep, rows, row, field),
    do: parse_quoted(rest, sep, rows, row, field <> <<c::utf8>>)

  # A quote never closed: what there is, is the field.
  defp parse_quoted("", sep, rows, row, field), do: parse_field("", sep, rows, row, field)

  # After a closing quote, anything up to the separator is kept as written.
  defp after_quote(rest, sep, rows, row, field), do: parse_field(rest, sep, rows, row, field)
end
