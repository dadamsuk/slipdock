defmodule SlipdockWeb.LedgerDocsTest do
  @moduledoc """
  The ledger (#1948) as the docs describe it: the API guide's recipe, the
  `activity` tool's ledger view, docs/agents.md, the README, the manual's
  section and its doors, the help pages and the CLI's help.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  @root Path.expand("../..", __DIR__)
  defp read(path), do: File.read!(Path.join(@root, path))
  defp flat(path), do: path |> read() |> String.replace(~r/\s+/, " ")

  test "the API guide gives the endpoint, the CLI and the MCP view" do
    guide = SlipdockWeb.APIGuide.markdown()
    assert guide =~ ~s|B/api/boards/1/ledger?since=1|
    assert guide =~ "slipdock ledger <board> [--since S]"
    assert guide =~ ~s|MCP: activity view: "ledger"|
    assert guide =~ "GET    /api/boards/:board/ledger"
  end

  test "the activity tool offers the ledger as a view" do
    tool = SlipdockWeb.MCP.Tools.Activity
    assert tool.description() =~ "view=ledger"
    assert tool.input_schema().properties.view.enum == ["log", "ledger"]
    assert Map.has_key?(tool.input_schema().properties, :since)
  end

  test "docs/agents.md names every door and the fields" do
    agents = flat("docs/agents.md")
    assert agents =~ "**The ledger.**"
    assert agents =~ "`slipdock ledger <board> [--since S]`"
    assert agents =~ "`GET /api/boards/:board/ledger?since=`"
    assert agents =~ ~s|MCP `activity` with `view: "ledger"`|
    assert agents =~ "(`/boards/:id/ledger`)"
    assert agents =~ "(`should_broken`)"
  end

  test "the manual has the section, its doors and the activity row" do
    manual = read("docs/manual.md")
    assert manual =~ "\n## The ledger\n"
    assert manual =~ "[The ledger](#the-ledger)"
    assert manual =~ "slipdock ledger slipdock --since 7"
    assert manual =~ "GET /api/boards/:board/ledger?since="

    assert manual =~
             "**The Ledger page.** Each board has one at `/boards/:id/ledger`, a tile\non the board's [Agentic Building](#agentic-building) page."

    assert manual =~ ~s|`view: "ledger"` (with `since`) gives the [ledger](#the-ledger)|

    assert flat("docs/manual.md") =~
             "The window starts at 07:00 yesterday, in the board's timezone"
  end

  test "the README lists it with its doors" do
    readme = flat("README.md")

    assert readme =~
             "- **Ledger** — [what shipped since yesterday, to skim](docs/manual.md#the-ledger)"

    assert readme =~ "`slipdock ledger <board> [--since S]`"
    assert readme =~ "`GET /api/boards/:board/ledger?since=`"
  end

  test "the CLI's help lists the command" do
    assert read("cli/help.txt") =~ "ledger <board> [--since S]"
  end

  test "the help pages describe it", %{conn: conn} do
    {:ok, _view, guides} = live(conn, "/help/boards")
    assert guides =~ "Ledger"
    assert guides =~ "Look closer"

    {:ok, _view, flow} = live(conn, "/help/agents/flow")
    assert flow =~ "Ledger page"
    assert flow =~ "slipdock ledger B [--since 7]"
  end
end
