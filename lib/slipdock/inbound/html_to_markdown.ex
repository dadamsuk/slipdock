defmodule Slipdock.Inbound.HtmlToMarkdown do
  @moduledoc """
  The HTML of an email as Markdown, for mail that has no text part (#1238).

  A small walker over Floki's tree, rather than a Hex converter: mail HTML
  needs things a general converter doesn't do (layout tables, Outlook's
  `o:`/`v:`/`w:` tags, tracking pixels, `cid:` images) and the subset of
  Markdown it should produce is small. What it keeps:

    * headings, paragraphs, line breaks (`<br>`, and Gmail's one `<div>` per
      line), rules
    * bold, italic, strikethrough, inline code, `<pre>` as a fenced block
    * links (http, https and mailto only), lists (nested), block quotes
    * tables as GFM tables, unless a cell holds blocks or another table, in
      which case the table is layout and its cells are read in order
    * images with an http(s) source, and `cid:` images through `:cid`

  It drops `<head>`, styles, scripts, comments, Office namespace tags, images
  no bigger than 1×1 or hidden (tracking pixels), `data:` images and any
  `cid:` image it has no reference for. Line breaks are newlines because
  card and page Markdown renders with hard breaks.
  """

  @drop ~w(head style script title meta link noscript template object embed iframe svg button input select textarea form)
  # Where a line-like block (a <div>, a layout cell) starts or ends: a line
  # break, unless a paragraph break is already there. `tidy/1` settles it.
  @line "\u0001"

  @blocks ~w(p div h1 h2 h3 h4 h5 h6 ul ol li blockquote pre table hr center section article header footer)

  @doc """
  Converts `html`. Options:

    * `:cid` — a function from a `cid:` content id (without `cid:` or angle
      brackets) to the URL to use for it, or nil to drop the image
  """
  @spec convert(String.t(), keyword()) :: String.t()
  def convert(html, opts \\ []) when is_binary(html) do
    ctx = %{cid: Keyword.get(opts, :cid, fn _ -> nil end), pre: false}

    case Floki.parse_document(html) do
      {:ok, tree} ->
        tree
        |> body()
        |> blocks(ctx)
        |> IO.iodata_to_binary()
        |> tidy()

      {:error, _} ->
        html |> Floki.text() |> tidy()
    end
  end

  # Only what is in <body>, when there is one.
  defp body(tree) do
    case Floki.find(tree, "body") do
      [{"body", _, children} | _] -> children
      _ -> tree
    end
  end

  ## Blocks: each renders to text separated from the next by blank lines.

  defp blocks(nodes, ctx), do: Enum.map(nodes, &node(&1, ctx))

  defp node(text, ctx) when is_binary(text), do: if(ctx.pre, do: text, else: inline_text(text))
  defp node({:comment, _}, _ctx), do: []
  defp node({:pi, _, _}, _ctx), do: []
  defp node({:doctype, _, _, _}, _ctx), do: []

  defp node({tag, attrs, children}, ctx) do
    tag = String.downcase(tag)

    cond do
      tag in @drop or office?(tag) or hidden?(attrs) -> []
      true -> element(tag, attrs, children, ctx)
    end
  end

  defp node(_, _ctx), do: []

  defp element("br", _, _, _ctx), do: "\n"
  defp element("hr", _, _, _ctx), do: "\n\n---\n\n"

  defp element("h" <> n, _, children, ctx) when n in ~w(1 2 3 4 5 6) do
    text = children |> inline(ctx) |> one_line()

    if text == "",
      do: [],
      else: ["\n\n", String.duplicate("#", String.to_integer(n)), " ", text, "\n\n"]
  end

  defp element("p", _, children, ctx), do: ["\n\n", blocks(children, ctx), "\n\n"]

  defp element(tag, _, children, ctx) when tag in ~w(div center section article header footer),
    do: [@line, blocks(children, ctx), @line]

  defp element(tag, _, children, ctx) when tag in ~w(strong b),
    do: wrap("**", children, ctx)

  defp element(tag, _, children, ctx) when tag in ~w(em i), do: wrap("*", children, ctx)
  defp element(tag, _, children, ctx) when tag in ~w(s strike del), do: wrap("~~", children, ctx)

  defp element("code", _, children, %{pre: true} = ctx), do: blocks(children, ctx)

  defp element("code", _, children, _ctx) do
    code = children |> Floki.text() |> String.replace(~r/\s+/, " ")
    if code == "", do: [], else: ["`", String.replace(code, "`", "'"), "`"]
  end

  defp element("pre", _, children, ctx) do
    code =
      children |> blocks(%{ctx | pre: true}) |> IO.iodata_to_binary() |> String.trim_trailing()

    fence = if String.contains?(code, "```"), do: "~~~", else: "```"
    ["\n\n", fence, "\n", code, "\n", fence, "\n\n"]
  end

  defp element("a", attrs, children, ctx) do
    text = children |> inline(ctx) |> one_line()
    href = attr(attrs, "href")

    cond do
      text == "" -> []
      not link?(href) -> text
      text == href or "mailto:" <> text == href -> ["<", href, ">"]
      true -> ["[", text, "](", escape_url(href), ")"]
    end
  end

  defp element("img", attrs, _, ctx) do
    src = attr(attrs, "src") || ""
    alt = (attr(attrs, "alt") || "") |> one_line() |> String.replace(~r/[\[\]]/, "")

    url =
      cond do
        pixel?(attrs) -> nil
        String.starts_with?(String.downcase(src), "cid:") -> ctx.cid.(cid(src))
        String.match?(src, ~r/^https?:\/\//i) -> src
        true -> nil
      end

    if url, do: ["![", alt, "](", escape_url(url), ")"], else: []
  end

  defp element(tag, _, children, ctx) when tag in ~w(ul ol) do
    items = Enum.filter(children, &match?({"li", _, _}, &1))

    lines =
      items
      |> Enum.with_index(1)
      |> Enum.map(fn {{"li", _, item}, n} ->
        marker = if tag == "ol", do: "#{n}. ", else: "- "
        body = item |> blocks(ctx) |> IO.iodata_to_binary() |> tidy()
        indent = String.duplicate(" ", String.length(marker))
        [marker, String.replace(body, "\n", "\n" <> indent), "\n"]
      end)

    ["\n\n", lines, "\n\n"]
  end

  # An <li> outside a list: read it as a line.
  defp element("li", _, children, ctx), do: ["\n- ", blocks(children, ctx), "\n"]

  defp element("blockquote", _, children, ctx) do
    quoted = children |> blocks(ctx) |> IO.iodata_to_binary() |> tidy()
    if quoted == "", do: [], else: ["\n\n", quote_lines(quoted), "\n\n"]
  end

  defp element("table", _, children, ctx) do
    rows = rows(children)

    if layout?(rows) do
      # Layout, not data: each cell in order, as blocks.
      cells =
        for {_, _, row} <- rows, {_, _, cell} <- cells(row), do: [@line, blocks(cell, ctx), @line]

      ["\n\n", cells, "\n\n"]
    else
      table(rows, ctx)
    end
  end

  # Anything else (span, font, u, small, sup, tbody outside a table, …):
  # its children, as they are.
  defp element(_tag, _, children, ctx), do: blocks(children, ctx)

  defp wrap(mark, children, ctx) do
    text = children |> inline(ctx) |> String.trim()
    if text == "", do: [], else: [mark, text, mark]
  end

  ## Tables

  defp rows(children) do
    Enum.flat_map(children, fn
      {tag, _, kids} when tag in ~w(thead tbody tfoot) -> rows(kids)
      {"tr", _, _} = row -> [row]
      _ -> []
    end)
  end

  defp cells(row), do: Enum.filter(row, &match?({tag, _, _} when tag in ~w(td th), &1))

  defp layout?([]), do: true

  defp layout?(rows) do
    Enum.any?(rows, fn {_, _, row} ->
      Enum.any?(cells(row), fn {_, _, cell} -> Floki.find(cell, Enum.join(@blocks, ",")) != [] end)
    end) or Enum.all?(rows, fn {_, _, row} -> length(cells(row)) <= 1 end)
  end

  defp table(rows, ctx) do
    grid =
      Enum.map(rows, fn {_, _, row} ->
        Enum.map(cells(row), fn {_, _, cell} ->
          cell |> inline(ctx) |> one_line() |> String.replace("|", "\\|")
        end)
      end)

    width = grid |> Enum.map(&length/1) |> Enum.max()
    [header | body] = Enum.map(grid, &(&1 ++ List.duplicate("", width - length(&1))))
    line = fn cells -> ["| ", Enum.intersperse(cells, " | "), " |\n"] end

    ["\n\n", line.(header), line.(List.duplicate("---", width)), Enum.map(body, line), "\n\n"]
  end

  ## Text

  defp inline(children, ctx), do: children |> blocks(ctx) |> IO.iodata_to_binary()

  defp one_line(text), do: text |> String.replace(~r/\s+/, " ") |> String.trim()

  # Whitespace collapsed as a browser would, and the characters that would
  # otherwise turn into Markdown escaped.
  defp inline_text(text) do
    text
    |> String.replace(~r/[ \t\r\n\x{00A0}]+/u, fn ws ->
      if String.contains?(ws, " "), do: " ", else: " "
    end)
    |> String.replace(~r/([\\`*_\[\]])/, "\\\\\\1")
  end

  defp quote_lines(text) do
    text
    |> String.split("\n")
    |> Enum.map_join("\n", fn
      "" -> ">"
      line -> "> " <> line
    end)
  end

  # Blank lines at most two at a time, no trailing spaces, no whitespace-only
  # lines, nothing at either end.
  defp tidy(text) do
    text
    |> String.replace(~r/[\n\x{0001}]+/u, fn run ->
      if String.contains?(run, "\n\n"), do: "\n\n", else: "\n"
    end)
    |> String.replace(" ", " ")
    |> String.split("\n")
    |> Enum.map(&String.trim_trailing/1)
    |> Enum.map(fn line -> if String.trim(line) == "", do: "", else: line end)
    |> Enum.join("\n")
    |> String.replace(~r/\n{3,}/, "\n\n")
    |> String.trim()
  end

  ## Attributes

  defp attr(attrs, name) do
    case List.keyfind(attrs, name, 0) do
      {_, value} -> String.trim(value)
      nil -> nil
    end
  end

  defp office?(tag), do: String.match?(tag, ~r/^(o|v|w|m|st1):/)

  defp hidden?(attrs) do
    style = (attr(attrs, "style") || "") |> String.downcase() |> String.replace(" ", "")

    String.contains?(style, "display:none") or String.contains?(style, "visibility:hidden") or
      List.keymember?(attrs, "hidden", 0)
  end

  defp pixel?(attrs) do
    small = fn name ->
      case attr(attrs, name) do
        nil -> false
        value -> match?({n, _} when n <= 1, Integer.parse(value))
      end
    end

    small.("width") or small.("height")
  end

  defp link?(nil), do: false
  defp link?(href), do: String.match?(href, ~r/^(https?:\/\/|mailto:)/i)

  defp cid(src) do
    src |> String.slice(4..-1//1) |> URI.decode() |> String.trim("<") |> String.trim(">")
  end

  defp escape_url(url), do: url |> String.replace(" ", "%20") |> String.replace(")", "%29")
end
