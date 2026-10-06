defmodule SlipdockWeb.API.GuideTest do
  use SlipdockWeb.ConnCase, async: true

  import Slipdock.Fixtures

  @tag :anonymous
  test "the guide reads without a token, and says what a token would add", %{conn: conn} do
    body = conn |> get(~p"/api/guide") |> response(200)

    assert body =~ "# Slipdock for agents"
    assert body =~ "Top-level cards are epics"
    assert body =~ "## Choosing what to do next"
    assert body =~ "Not shown: this request carried no token"

    # The endpoint list and the vocabularies are generated, not written out.
    assert body =~ "POST   /api/cards/:id/subboard"
    assert body =~ "`:board` accepts an id, a board's `code`, or a name."
    assert body =~ "critical > high > medium > low > none"
    assert body =~ "flagged · blocked · review · waiting · starred"
  end

  @tag :anonymous
  test "the guide points MCP clients at /mcp and names every tool it offers", %{conn: conn} do
    body = conn |> get(~p"/api/guide") |> response(200)

    assert body =~ "### Over MCP"
    assert body =~ "http://www.example.com/mcp"
    # Both ways in: a pasted token, and the browser sign-in connectors use.
    assert body =~ "same bearer token as the API"
    assert body =~ "OAuth 2.1"

    # Written out by hand, so this is what notices a tool added without it.
    for tool <- SlipdockWeb.MCP.Tools.all() do
      assert body =~ "`#{tool.name()}`", "the guide does not mention #{tool.name()}"
    end
  end

  @tag :anonymous
  test "the automations section lists the real vocabulary and endpoints", %{conn: conn} do
    body = conn |> get(~p"/api/guide") |> response(200)

    assert body =~ "## Automations and alerts"
    # Generated from Slipdock.Automations.Spec, so it cannot drift from the runner.
    assert body =~ "card_stale"
    assert body =~ "notify_assignee"
    assert body =~ "{{card.url}}"
    assert body =~ "POST   /api/boards/:board/automations"
    assert body =~ "DELETE /api/alerts/:id"
  end

  test "with a token it names the reader and their boards", %{conn: conn, user: user} do
    board = board_fixture(%{"name" => "Launch"}, owner: user)
    card_fixture(hd(board.columns), %{"title" => "An epic"})

    body = conn |> get(~p"/api/guide") |> response(200)

    assert body =~ "you are **#{user.email}**"
    assert body =~ "**##{board.id} Launch** (`launch`)"
    assert body =~ "the short name for"
    # The default lists carry categories, so the roles resolve.
    assert body =~ "take work from: “To Do”"
    assert body =~ "in progress: “In Progress”"
  end

  test "a board whose lists have no categories is still read by name", %{conn: conn, user: user} do
    board = board_fixture(%{"name" => "Legacy"}, owner: user)

    for col <- board.columns,
        do: {:ok, _} = Slipdock.Boards.update_column(col, %{"category" => ""})

    body = conn |> get(~p"/api/guide") |> response(200)

    assert body =~ "To Do (todo by name only"
    assert body =~ "take work from: “To Do”"
  end

  test "?format=json carries the guide plus the generated parts", %{conn: conn} do
    body = conn |> get(~p"/api/guide?format=json") |> json_response(200)

    assert body["guide"] =~ "# Slipdock for agents"
    assert body["vocabulary"]["priority_order"] == ~w(critical high medium low none)
    assert %{"method" => "POST", "path" => "/api/cards/:id/subboard"} in body["endpoints"]

    triggers = Enum.map(body["vocabulary"]["automations"]["triggers"], & &1["type"])
    assert "card_created" in triggers and "card_stale" in triggers
  end
end
