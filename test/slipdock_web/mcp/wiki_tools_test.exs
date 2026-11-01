defmodule SlipdockWeb.MCP.WikiToolsTest do
  @moduledoc """
  `wiki_info` and `manage_wiki` (W-2201): the caller's one wiki over MCP,
  checked as the API checks it. No tool names a vault.
  """
  use SlipdockWeb.ConnCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Accounts, Vaults}

  setup %{user: user} do
    board_fixture(%{"name" => "Keystone", "code" => "kb8"}, owner: user)
    jobs = board_fixture(%{"name" => "Journal Desk", "code" => "jobs5"}, owner: user)
    {:ok, _} = Slipdock.Wiki.create_folder(jobs, %{"name" => "Notes"})
    :ok
  end

  defp call(conn, tool, args) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post(
      "/mcp",
      Jason.encode!(%{
        jsonrpc: "2.0",
        id: 1,
        method: "tools/call",
        params: %{name: tool, arguments: args}
      })
    )
    |> json_response(200)
    |> Map.fetch!("result")
  end

  defp ok!(result) do
    assert result["isError"] == false, inspect(result["content"])
    result["structuredContent"]
  end

  defp error!(result) do
    assert result["isError"] == true
    [%{"text" => text}] = result["content"]
    text
  end

  test "wiki_info describes the wiki and its Knowledge Base; path gives the board", %{
    conn: conn,
    user: user
  } do
    wiki = ok!(call(conn, "wiki_info", %{}))["wiki"]
    kb = Slipdock.Wiki.KnowledgeBase.get(user)

    assert wiki["knowledge_base"]["id"] == kb.id
    assert wiki["url"] == "/wiki"
    refute Map.has_key?(wiki, "name")

    assert Enum.sort(Enum.map(wiki["boards"], & &1["path"])) ==
             ["/Journal Desk", "/Keystone", "/Knowledge Base"]

    located = ok!(call(conn, "wiki_info", %{path: "/Journal Desk/a.md"}))
    assert located["board"]["code"] == "jobs5"
    assert located["board"]["path"] == "/Journal Desk"
    assert located["rest"] == "a.md"
  end

  test "manage_wiki sets the wiki's shortcut, and there is no renaming it", %{
    conn: conn,
    user: user
  } do
    set = ok!(call(conn, "manage_wiki", %{action: "set", shortcut: "wq"}))
    assert set["wiki"]["shortcut"] == "wq"
    assert Vaults.root(user).shortcut == "wq"

    assert error!(call(conn, "manage_wiki", %{action: "rename"})) =~ "action must be one of"
    assert error!(call(conn, "manage_wiki", %{action: "set", name: "Brain"})) =~ "no argument"
  end

  test "no tool names a vault, or takes a vault argument", %{conn: conn} do
    %{"tools" => tools} =
      conn
      |> put_req_header("content-type", "application/json")
      |> post("/mcp", Jason.encode!(%{jsonrpc: "2.0", id: 1, method: "tools/list"}))
      |> json_response(200)
      |> Map.fetch!("result")

    names = Enum.map(tools, & &1["name"])
    assert "wiki_info" in names
    assert "manage_wiki" in names
    refute Enum.any?(names, &(&1 =~ "vault"))

    for tool <- tools do
      refute Map.has_key?(tool["inputSchema"]["properties"] || %{}, "vault"), tool["name"]
    end

    tool = Enum.find(tools, &(&1["name"] == "manage_wiki"))
    assert tool["inputSchema"]["properties"]["action"]["enum"] == ["set", "move_folder"]
  end

  test "mistakes come back as sentences", %{conn: conn} do
    assert error!(call(conn, "manage_wiki", %{action: "fly"})) =~ "action must be one of"
    assert error!(call(conn, "wiki_info", %{path: "/x.md"})) =~ "board"
    assert error!(call(conn, "wiki_info", %{path: "/Nope/x.md"})) =~ "board"
    assert error!(call(conn, "wiki_info", %{path: "/a/../b"})) =~ ".."
    assert error!(call(conn, "wiki_info", %{changes_since: -1})) =~ "cursor"
  end

  test "a read-only token may look but not change", %{user: user} do
    {token, _} = Accounts.create_api_token(user, "reader", scope: "read")
    conn = build_conn() |> put_req_header("authorization", "Bearer " <> token)

    assert %{"wiki" => _} = ok!(call(conn, "wiki_info", %{}))

    assert error!(call(conn, "manage_wiki", %{action: "set", shortcut: "zz"})) =~
             "read-only"
  end

  test "wiki_info resolves a link; page_info lists the wiki's wanted pages", %{
    conn: conn,
    user: user
  } do
    {:ok, kb} = Slipdock.Access.find_board(user, "kb8")
    {:ok, jobs} = Slipdock.Access.find_board(user, "jobs5")
    {:ok, note} = Slipdock.Wiki.create_page(jobs, %{"title" => "Acme"}, user: user)
    {:ok, _} = Slipdock.Wiki.create_page(kb, %{"title" => "L", "body" => "[[Ghost]]"}, user: user)

    found = ok!(call(conn, "wiki_info", %{link: "Acme"}))
    assert found["page"]["code"] == note.code
    assert found["path"] == "/Journal Desk/Acme"

    wanted = ok!(call(conn, "page_info", %{what: "wanted"}))
    assert wanted["wiki"] == true
    assert [%{"title" => "Ghost"}] = wanted["wanted"]
  end

  test "wiki_info gives the change feed after a cursor", %{conn: conn, user: user} do
    {:ok, kb} = Slipdock.Access.find_board(user, "kb8")
    {:ok, _} = Slipdock.Wiki.create_page(kb, %{"title" => "Fresh"}, user: user)

    feed = ok!(call(conn, "wiki_info", %{changes_since: 0}))
    assert Enum.any?(feed["changes"], &(&1["title"] == "Fresh"))
    assert is_integer(feed["cursor"])
  end

  test "move_folder: a dry run, then the move, then a refusal", %{conn: conn} do
    jobs = Slipdock.Repo.get_by!(Slipdock.Boards.Board, code: "jobs5")

    dry =
      ok!(
        call(conn, "manage_wiki", %{
          action: "move_folder",
          board: "jobs5",
          folder: "Notes",
          to_board: "kb8",
          dry_run: true
        })
      )

    assert dry["dry_run"] == true
    assert dry["report"]["folders"] == 1

    moved =
      ok!(
        call(conn, "manage_wiki", %{
          action: "move_folder",
          board: "jobs5",
          folder: "Notes",
          to_board: "kb8"
        })
      )

    assert moved["folder"]["name"] == "Notes"
    refute moved["folder"]["board_id"] == jobs.id

    assert error!(
             call(conn, "manage_wiki", %{
               action: "move_folder",
               board: "kb8",
               folder: "Notes",
               to_board: "kb8"
             })
           ) =~ "on that board already"
  end
end
