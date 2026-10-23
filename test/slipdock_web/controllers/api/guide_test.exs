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
  test "the guide, in its short form too, asks for comments in readable Markdown", %{conn: conn} do
    body = conn |> get(~p"/api/guide") |> response(200)
    assert body =~ "a bold first line, then short bullets"
    assert body =~ "never one dense\n  paragraph"

    assert SlipdockWeb.APIGuide.short() =~ "a bold first line, then short bullets"
    assert SlipdockWeb.MCP.Tools.Comment.description() =~ "not one dense paragraph"
  end

  @tag :anonymous
  test "finishing a card: re-read it, and leave a handoff only for the person", %{conn: conn} do
    body = conn |> get(~p"/api/guide") |> response(200)
    [_, finish] = String.split(body, "### Finish it", parts: 2)
    assert finish =~ "Re-read the card before committing, and its comments once the build\nstarts"

    assert finish =~
             "A done card's handoff is only\nwhat the person must do or check; else `{\"clear\": true}`."

    assert SlipdockWeb.APIGuide.short() =~ "Re-read the card before committing"
  end

  @tag :anonymous
  test "the guide says how to install the CLI on Windows, from this server", %{conn: conn} do
    body = conn |> get(~p"/api/guide") |> response(200)
    assert body =~ "irm http://www.example.com/cli/install.ps1 | iex"
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
  test "the runners section explains the action, the trust line and both ways in", %{conn: conn} do
    body = conn |> get(~p"/api/guide") |> response(200)

    assert body =~ "## Runners"
    assert body =~ ~s({"type": "runner", "pool": "default", "kind": "claude")
    assert body =~ "The server never decides what runs"
    assert body =~ "/api/boards/1/jobs/claim"
    assert body =~ "POST /api/runner/claim?wait=25"
    assert body =~ "`Retry-After: 1`"
    assert body =~ "/api/jobs/:id/cancel"
    assert body =~ "`claim_job`, `job_progress` and"
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
    assert body =~ "**##{board.id} Launch** (`#{board.code}`)"
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

  @tag :anonymous
  test "the guide describes a meeting page, and the vault sync section points at it", %{
    conn: conn
  } do
    body = conn |> get(~p"/api/guide") |> response(200)

    assert body =~ "### Meeting pages (recordings on Google Drive)"
    assert body =~ "recording: gdrive:Meeting Recordings/"
    assert body =~ "[▶ Play recording and transcript](#recording)"
    assert body =~ "```vtt"
    assert body =~ "Tags: #important (0:05) #action (12:40)"
    assert body =~ ~s(PATCH /api/vaults/:id {"recordings_folder":)
    assert body =~ "GET /api/me/drive"
    assert body =~ "slipdock drive status"

    assert body =~ "recorded meeting is a page like any other: see *Meeting pages* below"

    # The endpoints are in the generated list too.
    assert body =~ "GET    /api/me/drive"
  end

  @tag :anonymous
  test "the wiki section says a folder can be filed in several places (#808)", %{conn: conn} do
    body = conn |> get(~p"/api/guide") |> response(200)

    assert body =~ "**One folder, several places.**"
    assert body =~ ~s(PATCH /api/folders/4 {"also": "Ideas"})
    assert body =~ "never inside its own subtree (through placements too)"
    assert body =~ "slipdock folder file <board> <folder> --also F | --not-in F"
    assert body =~ "MCP: `file_folder`"
    assert body =~ "GET    /api/boards/:board/folders/*id"
  end

  test "the guide explains sharing pages and folders, and every refusal code (#820)", %{
    conn: conn
  } do
    body = conn |> get("/api/guide") |> response(200)

    assert body =~ "**Sharing a page or a folder**"

    assert body =~
             "POST -H \"$H\" -H 'content-type: application/json' \\\n     B/api/pages/W-31/grants"

    assert body =~ "B/api/shared"
    assert body =~ "slipdock page share <page> <email|group> [--write] [--off]"
    assert body =~ "`list_pages {\"shared\": true}`"

    for code <- Map.keys(Slipdock.Wiki.Sharing.codes()) do
      assert body =~ "`#{code}`", "the guide does not name #{code}"
    end
  end

  test "the guide says a drawing may be live and how a write to one lands (#826)", %{conn: conn} do
    body = conn |> get(~p"/api/guide") |> response(200)

    assert body =~ "A drawing may be **live**"
    assert body =~ "wins only if you bumped its `version`"
    assert body =~ "set `isDeleted: true` and bump `version` to delete"
    assert body =~ "Their next autosave holds both sides"
  end
end
