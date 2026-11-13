defmodule Slipdock.ManualPagesTest do
  @moduledoc """
  The manual in pages (#2232). As one file it was over the 512 KB GitHub
  will render, so it showed nothing. Now `docs/manual.md` is the way in: the
  introduction and a contents list linking each part under `docs/manual/`,
  one per section. These hold it to that: every part listed and under the
  limit, each linking back to the contents, and every link into the manual,
  from anywhere in the docs or the skills, landing on a file and a heading
  that are there.
  """
  use ExUnit.Case, async: true

  alias Slipdock.DocsText

  @root Path.expand("../..", __DIR__)
  @index Path.join(@root, "docs/manual.md")
  @render_limit 512 * 1024

  defp rel(path), do: Path.relative_to(path, @root)
  defp on_disk, do: Path.wildcard(Path.join(@root, "docs/manual/*.md")) |> Enum.sort()

  # Markdown files that may link into the manual.
  defp sources do
    ["README.md", "docs/**/*.md", "priv/skills/**/*.md"]
    |> Enum.flat_map(&Path.wildcard(Path.join(@root, &1)))
    |> Enum.uniq()
  end

  # Lines outside fenced code, with inline code taken out: a link written
  # as an example (`[Play](#recording)`) is not a link.
  defp prose(text) do
    text
    |> String.split("\n")
    |> Enum.reduce({[], false}, fn line, {acc, fenced} ->
      cond do
        line =~ ~r/^\s*(```|~~~)/ -> {acc, not fenced}
        fenced -> {acc, fenced}
        true -> {[String.replace(line, ~r/`[^`]*`/, "") | acc], fenced}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  @doc false
  # GitHub's anchor for a heading: lower case, the link text kept, anything
  # but letters, digits, `_`, `-` and spaces dropped, spaces as `-`.
  def slug(heading) do
    heading
    |> String.downcase()
    |> String.replace(~r/\[([^\]]*)\]\([^)]*\)/u, "\\1")
    |> String.replace(~r/[^\w\- ]/u, "")
    |> String.replace(" ", "-")
  end

  @doc false
  # Every anchor in a Markdown text; a repeated heading gets `-1`, `-2`.
  def anchors(text) do
    text
    |> prose()
    |> Enum.flat_map(fn line ->
      case Regex.run(~r/^\#{1,6} +(.*?)\s*$/, line) do
        [_, heading] -> [slug(heading)]
        nil -> []
      end
    end)
    |> Enum.reduce({[], %{}}, fn slug, {acc, seen} ->
      n = Map.get(seen, slug, 0)
      {[if(n == 0, do: slug, else: "#{slug}-#{n}") | acc], Map.put(seen, slug, n + 1)}
    end)
    |> elem(0)
    |> MapSet.new()
  end

  @doc false
  # The headings after a part's footer: its last `---` outside fenced code,
  # which only the contents and neighbours links should follow (#2906).
  def headings_after_footer(text) do
    lines = prose(text)

    case lines |> Enum.with_index() |> Enum.filter(fn {l, _} -> l == "---" end) |> List.last() do
      nil -> []
      {_, at} -> lines |> Enum.drop(at + 1) |> Enum.filter(&(&1 =~ ~r/^\#{1,6} /))
    end
  end

  defp links(text) do
    for line <- prose(text), [_, target] <- Regex.scan(~r/\]\(([^)\s]+)\)/, line), do: target
  end

  # The links in `path` that land in the manual, each as {file, anchor | nil}.
  defp manual_links(path) do
    for target <- links(File.read!(path)),
        not String.match?(target, ~r{^[a-z][a-z+.-]*:|^/}i),
        [file | anchor] = String.split(target, "#", parts: 2),
        dest = if(file == "", do: path, else: Path.expand(file, Path.dirname(path))),
        dest == @index or Path.dirname(dest) == Path.join(@root, "docs/manual"),
        do: {dest, List.first(anchor)}
  end

  describe "the contents" do
    test "lists every part once, and only parts that are there" do
      listed = DocsText.manual_parts()
      assert listed != []
      assert listed -- Enum.uniq(listed) == [], "the contents list a part twice"
      assert Enum.sort(listed) == on_disk(), "docs/manual/ and the contents disagree"
    end

    test "stays short: it is the way in, not the manual" do
      assert File.stat!(@index).size < 64 * 1024
    end
  end

  describe "the parts" do
    test "each is under the size GitHub will render" do
      for path <- [@index | on_disk()] do
        assert File.stat!(path).size < @render_limit, "#{rel(path)} is too big to show"
      end
    end

    test "each opens with its section's heading under a link back to the contents" do
      for path <- on_disk() do
        assert ["[Slipdock — the manual](../manual.md)", "", "## " <> heading | _] =
                 String.split(File.read!(path), "\n"),
               rel(path)

        assert slug(heading) <> ".md" == Path.basename(path),
               "#{rel(path)} is named for its section"
      end
    end

    test "each ends with the contents and its neighbours, in the contents' order" do
      parts = DocsText.manual_parts()

      for {path, i} <- Enum.with_index(parts) do
        foot = File.read!(path) |> String.split("\n---\n") |> List.last()
        assert foot =~ "[Contents](../manual.md)", rel(path)

        if i > 0 do
          previous = Path.basename(Enum.at(parts, i - 1))
          assert foot =~ ~r/← \[[^\]]+\]\(#{Regex.escape(previous)}\)/, rel(path)
        end

        if i < length(parts) - 1 do
          next = Path.basename(Enum.at(parts, i + 1))
          assert foot =~ ~r/\]\(#{Regex.escape(next)}\) →/, rel(path)
        end
      end
    end

    test "none has a section after its footer" do
      stray =
        for path <- on_disk(),
            heading <- headings_after_footer(File.read!(path)),
            do: "#{rel(path)}: #{heading}"

      assert stray == [],
             "Move these above the page's footer, with a line in the contents:\n" <>
               Enum.join(stray, "\n")
    end
  end

  describe "links into the manual" do
    test "land on a file that is there and a heading it has, from anywhere" do
      broken =
        for source <- sources(),
            {dest, anchor} <- manual_links(source),
            not File.regular?(dest) or (anchor != nil and anchor not in anchors(File.read!(dest))),
            do: "#{rel(source)} → #{rel(dest)}##{anchor}"

      assert broken == [], "Links into the manual that land nowhere:\n" <> Enum.join(broken, "\n")
    end

    test "none is left pointing at a section of the old single page" do
      stale =
        for source <- sources(),
            {dest, anchor} <- manual_links(source),
            dest == @index and anchor not in [nil, "contents"],
            do: "#{rel(source)}: manual.md##{anchor}"

      assert stale == [], "Point these at the part that holds them:\n" <> Enum.join(stale, "\n")
    end
  end

  describe "the checks themselves" do
    test "slug/1 makes GitHub's anchors" do
      assert slug("Flow: the pulse, a card's state and its age") ==
               "flow-the-pulse-a-cards-state-and-its-age"

      assert slug("Planning an idea: the `slipdock-plan` skill") ==
               "planning-an-idea-the-slipdock-plan-skill"

      assert slug("[Web links](x.md) and more") == "web-links-and-more"
    end

    test "anchors/1 numbers repeats and skips fenced and inline code" do
      text = "## A\n\n### A\n\n```\n## Fenced\n```\n\n## B\n"
      assert anchors(text) == MapSet.new(["a", "a-1", "b"])
    end

    test "headings_after_footer/1 finds a section after the footer, not one in fenced code" do
      foot = "\n---\n\n← [A](a.md) · [Contents](../manual.md)\n"
      assert headings_after_footer("## A\n\n### B\n" <> foot) == []
      assert headings_after_footer("## A\n" <> foot <> "\n### Late\n") == ["### Late"]
      # Any level counts: the stray section this was written for was a `## `.
      assert headings_after_footer("## A\n" <> foot <> "\n# One\n\n## Two\n") == [
               "# One",
               "## Two"
             ]

      # The footer is the last rule: one mid-page doesn't fail what is under it.
      assert headings_after_footer("## A\n\n---\n\n### B\n" <> foot) == []

      assert headings_after_footer("## A\n\n---\n\n### B\n" <> foot <> "\n### Late\n") == [
               "### Late"
             ]

      assert headings_after_footer("## A\n" <> foot <> "\n```\n---\n## Fenced\n```\n") == []
      assert headings_after_footer("## A\n\n```\n---\n```\n\n### B\n" <> foot) == []
      assert headings_after_footer("## A\n\n### B\n") == []
    end

    test "a broken link is caught, an example in inline code is not" do
      dir = Path.join(System.tmp_dir!(), "manual_pages_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)
      md = Path.join(dir, "x.md")
      File.write!(md, "[a](#{@index}) [b](#{@root}/docs/manual/nope.md) `[c](#{@index})`\n")
      # Absolute targets are not links a reader can follow; nothing is taken.
      assert manual_links(md) == []

      File.write!(md, "[a](#{Path.relative_to(@index, dir, force: true)}#nowhere)\n")
      assert [{@index, "nowhere"}] = manual_links(md)
      refute "nowhere" in anchors(File.read!(@index))
    end
  end

  describe "DocsText" do
    test "reads the manual whole: every part's text is in it, in order" do
      whole = DocsText.read!("docs/manual.md")
      assert whole == DocsText.read!(@index)

      offsets =
        for path <- DocsText.manual_parts() do
          {at, _} = :binary.match(whole, File.read!(path))
          at
        end

      assert offsets == Enum.sort(offsets)
      assert String.starts_with?(whole, File.read!(@index))
    end

    test "reads any other file as it is" do
      assert DocsText.read!("docs/agents.md") == File.read!("docs/agents.md")
      assert_raise File.Error, fn -> DocsText.read!("docs/no-such-file.md") end
    end
  end
end
