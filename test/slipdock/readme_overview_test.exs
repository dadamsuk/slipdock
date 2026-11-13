defmodule Slipdock.ReadmeOverviewTest do
  @moduledoc """
  The README is the short way in, not the manual (#2792). It grew to 1,484
  lines with bullets of 2,000 characters, because every feature card wrote
  its detail there. The detail now lives in the manual: the feature list in
  `docs/manual/every-feature-in-brief.md`, running a server in the pages
  after *Running*, and the security notes in a page of their own. These
  hold the README to an overview: a few hundred lines, no bullet over a few
  lines, and a link to each page that took its detail.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)
  @max_lines 450
  @max_item_lines 6
  @max_item_chars 450

  defp readme, do: File.read!(Path.join(@root, "README.md"))

  @doc false
  # Each list item of a Markdown text, outside fenced code: its first line
  # (`- `, `* ` or `1. `) and the indented lines that continue it, as
  # `{line number, [lines]}`.
  def items(text) do
    text
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.reduce({[], nil, false}, &step/2)
    |> then(fn {done, open, _} -> close(done, open) end)
    |> Enum.reverse()
  end

  # One line into `{items done, the item open, inside fenced code?}`.
  defp step({line, n}, {done, open, fenced}) do
    case kind(line, fenced, open) do
      :fence -> {close(done, open), nil, not fenced}
      :code -> {done, open, fenced}
      :item -> {close(done, open), {n, [line]}, fenced}
      :more -> {done, put_elem(open, 1, [line | elem(open, 1)]), fenced}
      :other -> {close(done, open), nil, fenced}
    end
  end

  defp kind(line, fenced, open) do
    cond do
      line =~ ~r/^\s*(```|~~~)/ -> :fence
      fenced -> :code
      line =~ ~r/^\s*([-*]|\d+\.) / -> :item
      open != nil and line =~ ~r/^\s+\S/ -> :more
      true -> :other
    end
  end

  defp close(done, nil), do: done
  defp close(done, {n, lines}), do: [{n, Enum.reverse(lines)} | done]

  @doc false
  # The items over the limits, each as "line N: L lines, C characters".
  def long_items(text, max_lines \\ @max_item_lines, max_chars \\ @max_item_chars) do
    for {n, lines} <- items(text),
        chars = lines |> Enum.map_join(" ", &String.trim/1) |> String.length(),
        length(lines) > max_lines or chars > max_chars,
        do: "line #{n}: #{length(lines)} lines, #{chars} characters"
  end

  test "the README is a few hundred lines at most" do
    lines = readme() |> String.split("\n") |> length()

    assert lines <= @max_lines,
           "README.md is #{lines} lines: move the detail to a page of docs/manual/ and link it"
  end

  test "no bullet in it runs over a few lines" do
    long = long_items(readme())

    assert long == [],
           "README.md has list items that are too long; say it in a line or two and link " <>
             "the manual page that has the detail:\n" <> Enum.join(long, "\n")
  end

  test "it links each manual page that took its detail" do
    for page <- ~w(every-feature-in-brief docker-step-by-step running-it-for-other-people
                   receiving-email google-drive-for-meeting-recordings security-notes
                   runners machines tools mcp-server) do
      assert readme() =~ "(docs/manual/#{page}.md",
             "README.md doesn't link docs/manual/#{page}.md"

      assert File.regular?(Path.join(@root, "docs/manual/#{page}.md")), page
    end

    assert readme() =~ "[the manual](docs/manual.md)"
  end

  test "it still says how to get a server running" do
    text = readme()
    assert text =~ "curl -O https://raw.githubusercontent.com/dadamsuk/slipdock/main/compose.yaml"
    assert text =~ "sh setup.sh"
    assert text =~ "docker compose up -d"
    assert text =~ "docker compose logs slipdock"
    assert text =~ "mix setup"
  end

  describe "the checks themselves" do
    test "an item is its first line and the lines indented under it" do
      text = "intro\n\n- one\n  two\n\n  not part\n- three\n1. four\n   five\nplain\n"

      assert items(text) == [
               {3, ["- one", "  two"]},
               {7, ["- three"]},
               {8, ["1. four", "   five"]}
             ]
    end

    test "a list inside fenced code is not a list" do
      assert items("```sh\n- not an item\n```\n- an item\n") == [{4, ["- an item"]}]
      assert items("~~~\n- not an item\n~~~\n- an item\n") == [{4, ["- an item"]}]
    end

    test "a fence ends the open item, and indented lines after it don't join it" do
      assert items("- a\n```\ncode\n```\n  b\n") == [{1, ["- a"]}]
    end

    test "a `* ` bullet is an item too" do
      assert items("* a\n  b\n") == [{1, ["* a", "  b"]}]
    end

    test "a nested item is an item of its own, and ends its parent" do
      assert items("- parent\n  - child\n    more\n") == [
               {1, ["- parent"]},
               {2, ["  - child", "    more"]}
             ]
    end

    test "an item over either limit is named with its line, one within both is not" do
      many = "- a\n" <> String.duplicate("  b\n", 6)
      wide = "- " <> String.duplicate("x", 451) <> "\n"
      fine = "- a\n" <> String.duplicate("  b\n", 5)

      assert long_items(many) == ["line 1: 7 lines, 15 characters"]
      assert long_items(wide) == ["line 1: 1 lines, 453 characters"]
      assert long_items(fine) == []
      assert long_items("- " <> String.duplicate("x", 448)) == []
      assert long_items("- " <> String.duplicate("x", 449)) == ["line 1: 1 lines, 451 characters"]
      assert long_items("para\n\n" <> many) == ["line 3: 7 lines, 15 characters"]
    end

    test "the old README's longest bullet would have failed" do
      bullet = "- **A wiki per board** — " <> String.duplicate("and more of the same, ", 40)
      assert [_] = long_items(bullet)
    end
  end
end
