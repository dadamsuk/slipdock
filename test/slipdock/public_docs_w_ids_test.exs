defmodule Slipdock.PublicDocsWIdsTest do
  @moduledoc """
  The handbook is a wiki on the maintainers' board, and nobody outside can
  open it. So the public docs name its pages by title, never by a bare `W-`
  code an outsider can't follow (#3343): a code there either sits in the text
  of a Markdown link to a public `http(s)` URL, or isn't there.

  `W-1`, `W-3` and `W-31` are allowed. They are the product's own example page
  codes (`slipdock page ai W-31 …`, `[[W-31]]`), the way `#412` stands in for a
  card, and point at no handbook page. Use one of them for an example rather
  than a real page's code.
  """
  use ExUnit.Case, async: true

  @roots ["README.md", "CONTRIBUTING.md", "CLAUDE.md", "AGENTS.md"]
  @examples ~w(W-1 W-3 W-31)

  test "the public docs carry no W-id an outsider can't open" do
    offences =
      public_docs()
      |> Enum.flat_map(fn path ->
        path
        |> File.read!()
        |> String.split("\n")
        |> Enum.with_index(1)
        |> Enum.flat_map(fn {line, n} ->
          Enum.map(unlinked_w_ids(line), &"#{path}:#{n}: #{&1}")
        end)
      end)

    assert offences == [], """
    These W-ids point at handbook pages an outsider can't open. Name the page by
    its title instead ("the handbook's Testing & tooling page, §Tests"), link
    the code to a public URL, or use an example code (#{Enum.join(@examples, ", ")}):

    #{Enum.join(offences, "\n")}
    """
  end

  test "a bare code is caught; a linked one and the example codes are not" do
    assert unlinked_w_ids("The runbook is W-1951 §Runbooks.") == ["W-1951"]
    assert unlinked_w_ids("see W-1950 and W-2307") == ["W-1950", "W-2307"]
    assert unlinked_w_ids("`slipdock page ai W-31` or [[W-3]] or W-1") == []
    assert unlinked_w_ids("W-310 is not W-31") == ["W-310"]
    assert unlinked_w_ids("[W-1950 §Tests](https://example.com/handbook/tests)") == []
    assert unlinked_w_ids("https://example.com/pages/W-1950") == []
    assert unlinked_w_ids("[W-1950](handbook.md)") == ["W-1950"]
  end

  defp unlinked_w_ids(line) do
    line = Regex.replace(~r{\[[^\]]*\]\(https?://[^)\s]+\)|https?://\S+}, line, "")

    ~r/\bW-\d+\b/
    |> Regex.scan(line)
    |> List.flatten()
    |> Enum.reject(&(&1 in @examples))
  end

  defp public_docs do
    {out, 0} = System.cmd("git", ["ls-files", "docs"])

    docs =
      out
      |> String.split("\n", trim: true)
      |> Enum.reject(&binary_file?/1)

    Enum.filter(@roots, &File.exists?/1) ++ docs
  end

  defp binary_file?(path),
    do: Path.extname(path) in ~w(.png .jpg .jpeg .gif .webp .ico .pdf .woff .woff2)
end
