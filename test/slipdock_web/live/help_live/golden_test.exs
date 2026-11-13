defmodule SlipdockWeb.HelpLive.GoldenTest do
  @moduledoc """
  Every help page, as /help renders it, held to a copy of it (#2919). The
  pages' prose is HEEx under `lib/slipdock_web/live/help_live/guides/`,
  `agents/` and `flow/`, embedded into their modules, and the lists the hub
  and the pages are built from are data files beside them; a slip there (a
  template left out, a part in the wrong place, an attribute lost) changes
  the output, and this says which page and where.

  Each page is read twice, signed out and signed in, since the help links
  into the app only for a reader who is signed in. What is compared is the
  page's `#help` block: the layout around it carries the reader's own
  address and isn't the help's.

  A change to a page's text changes these on purpose: regenerate them with
  `GOLDEN=1 mix test test/slipdock_web/live/help_live/golden_test.exs` and
  read the diff of `test/slipdock_web/live/help_live/golden/` before
  committing it.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias SlipdockWeb.HelpLive.{Agents, Guides}

  @dir Path.expand("golden", __DIR__)

  # Each page: the name of its copy and its path.
  defp pages do
    [{"hub", "/help"}] ++
      for(s <- Guides.sections(), do: {"section-#{s.slug}", "/help/#{s.slug}"}) ++
      [{"agents", "/help/agents"}, {"agents-flow", "/help/agents/flow"}] ++
      for(t <- Agents.topics(), do: {"agents-#{t.slug}", "/help/agents/#{t.slug}"}) ++
      [{"agents-cli-reference", "/help/agents/cli/reference"}]
  end

  defp golden(name, html) do
    path = Path.join(@dir, name <> ".html")

    if System.get_env("GOLDEN") == "1" do
      File.mkdir_p!(@dir)
      File.write!(path, html)
    end

    expected = File.read!(path)

    if html != expected do
      flunk("""
      #{name}: the page differs from its copy, first at line #{first_difference(html, expected)}.
      If the change is meant, regenerate it with GOLDEN=1 (see the moduledoc).
      """)
    end
  end

  defp first_difference(a, b) do
    {as, bs} = {String.split(a, "\n"), String.split(b, "\n")}

    case Enum.zip(as, bs) |> Enum.find_index(fn {x, y} -> x != y end) do
      nil -> min(length(as), length(bs)) + 1
      i -> i + 1
    end
  end

  # The page's #help block, one tag or text run a line, so a difference is
  # reported at a line that means something.
  defp help_block(conn, path) do
    {:ok, view, _html} = live(conn, path)
    view |> element("#help") |> render() |> String.replace(">", ">\n")
  end

  test "the list of pages is every section and every agents' topic" do
    names = Enum.map(pages(), &elem(&1, 0))

    assert length(names) == length(Guides.sections()) + length(Agents.topics()) + 4
    assert names == Enum.uniq(names)
  end

  @tag :anonymous
  test "each page, signed out, is as its copy has it", %{conn: conn} do
    for {name, path} <- pages(), do: golden("#{name}.signed-out", help_block(conn, path))
  end

  test "each page, signed in, is as its copy has it", %{conn: conn} do
    for {name, path} <- pages(), do: golden("#{name}.signed-in", help_block(conn, path))
  end

  test "a page that differs is reported with the line it first differs at" do
    assert first_difference("a\nb\nc", "a\nx\nc") == 2
    assert first_difference("a\nb", "a\nb\nc") == 3
  end
end
