defmodule SlipdockWeb.MCP.VaultToolsTest do
  @moduledoc "`list_vaults` and `manage_vault`: vaults over MCP, checked as the API checks them."
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

  test "list_vaults describes the one vault; path gives the board and the rest", ctx do
    %{conn: conn, user: user} = ctx
    {:ok, vault} = user |> Vaults.root() |> Vaults.update_vault(%{"name" => "Notes"})

    assert [%{"id" => id, "name" => "Notes", "boards" => boards, "pages" => 0}] =
             ok!(call(conn, "list_vaults", %{}))["vaults"]

    assert id == vault.id
    assert Enum.map(boards, & &1["path"]) == ["/Journal Desk", "/Keystone"]
    assert ok!(call(conn, "list_vaults", %{vault: "notes"}))["vault"]["name"] == "Notes"

    located = ok!(call(conn, "list_vaults", %{vault: "Notes", path: "/Journal Desk/a.md"}))
    assert located["board"]["code"] == "jobs5"
    assert located["board"]["path"] == "/Journal Desk"
    assert located["rest"] == "a.md"
  end

  test "manage_vault renames the vault", %{conn: conn, user: user} do
    vault = Vaults.root(user)

    renamed = ok!(call(conn, "manage_vault", %{action: "rename", vault: vault.id, name: "Brain"}))

    assert renamed["vault"]["name"] == "Brain"
    assert {:ok, %{name: "Brain"}} = Vaults.get_vault(user, vault.id)
  end

  test "the actions that went with mounting are refused", %{conn: conn, user: user} do
    vault = Vaults.root(user)

    for action <- ~w(create delete map unmap inside split) do
      args = %{action: action, vault: vault.id, name: "More", board: "kb8"}
      assert error!(call(conn, "manage_vault", args)) =~ "action must be one of"
    end

    assert [%{id: id}] = Vaults.list_vaults(user)
    assert id == vault.id
  end

  test "the arguments that went with mounting are not offered", %{conn: conn} do
    %{"tools" => tools} =
      conn
      |> put_req_header("content-type", "application/json")
      |> post("/mcp", Jason.encode!(%{jsonrpc: "2.0", id: 1, method: "tools/list"}))
      |> json_response(200)
      |> Map.fetch!("result")

    tool = Enum.find(tools, &(&1["name"] == "manage_vault"))

    assert tool["inputSchema"]["properties"]["action"]["enum"] == ["rename", "move_folder"]

    for key <- ~w(path new_board confirm inside with_board),
        do: refute(Map.has_key?(tool["inputSchema"]["properties"], key))
  end

  test "mistakes come back as sentences", %{conn: conn, user: user} do
    assert error!(call(conn, "manage_vault", %{action: "fly"})) =~ "action must be one of"

    assert error!(call(conn, "manage_vault", %{action: "rename", vault: "Nope", name: "x"})) =~
             "vault"

    assert error!(call(conn, "list_vaults", %{path: "/x"})) =~ "which vault"

    assert {:ok, _} = user |> Vaults.root() |> Vaults.update_vault(%{"name" => "Notes"})

    assert error!(call(conn, "list_vaults", %{vault: "Notes", path: "/x.md"})) =~ "board"
    assert error!(call(conn, "list_vaults", %{vault: "Notes", path: "/Nope/x.md"})) =~ "board"
    assert error!(call(conn, "list_vaults", %{vault: "Notes", path: "/a/../b"})) =~ ".."
    assert error!(call(conn, "list_vaults", %{vault: "Nope"})) =~ "vault"
  end

  test "a read-only token may list but not change", %{user: user} do
    vault = Vaults.root(user)
    {token, _} = Accounts.create_api_token(user, "reader", scope: "read")
    conn = build_conn() |> put_req_header("authorization", "Bearer " <> token)

    assert [_] = ok!(call(conn, "list_vaults", %{}))["vaults"]

    assert error!(call(conn, "manage_vault", %{action: "rename", vault: vault.id, name: "More"})) =~
             "read-only"
  end

  test "list_vaults resolves a link, page_info lists a vault's wanted pages", %{
    conn: conn,
    user: user
  } do
    {:ok, _} = user |> Vaults.root() |> Vaults.update_vault(%{"name" => "Notes"})
    {:ok, kb} = Slipdock.Access.find_board(user, "kb8")
    {:ok, jobs} = Slipdock.Access.find_board(user, "jobs5")
    {:ok, note} = Slipdock.Wiki.create_page(jobs, %{"title" => "Acme"}, user: user)
    {:ok, _} = Slipdock.Wiki.create_page(kb, %{"title" => "L", "body" => "[[Ghost]]"}, user: user)

    found = ok!(call(conn, "list_vaults", %{vault: "Notes", link: "Acme"}))
    assert found["page"]["code"] == note.code
    assert found["path"] == "/Journal Desk/Acme"
    assert error!(call(conn, "list_vaults", %{link: "Acme"})) =~ "which vault"

    wanted = ok!(call(conn, "page_info", %{what: "wanted", vault: "Notes"}))
    assert [%{"title" => "Ghost"}] = wanted["wanted"]
  end

  test "list_vaults gives the change feed after a cursor", %{conn: conn, user: user} do
    {:ok, _} = user |> Vaults.root() |> Vaults.update_vault(%{"name" => "Notes"})
    {:ok, kb} = Slipdock.Access.find_board(user, "kb8")
    {:ok, _} = Slipdock.Wiki.create_page(kb, %{"title" => "Fresh"}, user: user)

    feed = ok!(call(conn, "list_vaults", %{vault: "Notes", changes_since: 0}))
    assert Enum.any?(feed["changes"], &(&1["title"] == "Fresh"))
    assert is_integer(feed["cursor"])
    assert error!(call(conn, "list_vaults", %{vault: "Notes", changes_since: -1})) =~ "cursor"
    assert error!(call(conn, "list_vaults", %{changes_since: 0})) =~ "vault"
  end

  test "move_folder: a dry run, then the move, then a refusal", %{conn: conn} do
    jobs = Slipdock.Repo.get_by!(Slipdock.Boards.Board, code: "jobs5")

    dry =
      ok!(
        call(conn, "manage_vault", %{
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
        call(conn, "manage_vault", %{
          action: "move_folder",
          board: "jobs5",
          folder: "Notes",
          to_board: "kb8"
        })
      )

    assert moved["folder"]["name"] == "Notes"
    refute moved["folder"]["board_id"] == jobs.id

    assert error!(
             call(conn, "manage_vault", %{
               action: "move_folder",
               board: "kb8",
               folder: "Notes",
               to_board: "kb8"
             })
           ) =~ "on that board already"
  end
end
