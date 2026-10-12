defmodule SlipdockWeb.MCP.VaultToolsTest do
  @moduledoc "`list_vaults` and `manage_vault`: vaults over MCP, checked as the API checks them."
  use SlipdockWeb.ConnCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Accounts, Vaults}

  setup %{user: user} do
    board_fixture(%{"name" => "KnowledgeBase", "code" => "kb"}, owner: user)
    jobs = board_fixture(%{"name" => "Job Hunt", "code" => "jobs"}, owner: user)
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

  test "make a vault, map it, list it, locate a path, unmap, rename, delete", %{
    conn: conn,
    user: user
  } do
    assert ok!(call(conn, "manage_vault", %{action: "create", name: "Notes"}))["vault"]["name"] ==
             "Notes"

    ok!(call(conn, "manage_vault", %{action: "map", vault: "Notes", path: "/", board: "kb"}))

    mapped =
      ok!(
        call(conn, "manage_vault", %{
          action: "map",
          vault: "Notes",
          path: "/Jobs",
          board: "jobs",
          folder: "Notes"
        })
      )

    assert Enum.map(mapped["vault"]["mappings"], & &1["path"]) == ["/", "/Jobs"]

    assert [%{"name" => "Notes"}] = ok!(call(conn, "list_vaults", %{}))["vaults"]
    assert ok!(call(conn, "list_vaults", %{vault: "notes"}))["vault"]["name"] == "Notes"

    located = ok!(call(conn, "list_vaults", %{vault: "Notes", path: "/Jobs/a.md"}))
    assert located["mapping"]["path"] == "/Jobs"
    assert located["rest"] == "a.md"

    unmapped = ok!(call(conn, "manage_vault", %{action: "unmap", vault: "Notes", path: "/Jobs"}))
    assert Enum.map(unmapped["vault"]["mappings"], & &1["path"]) == ["/"]

    ok!(call(conn, "manage_vault", %{action: "rename", vault: "Notes", name: "Brain"}))
    assert error!(call(conn, "manage_vault", %{action: "delete", vault: "Brain"})) =~ "confirm"
    ok!(call(conn, "manage_vault", %{action: "delete", vault: "Brain", confirm: true}))
    assert Vaults.list_vaults(user) == []
  end

  test "mistakes come back as sentences", %{conn: conn} do
    assert error!(call(conn, "manage_vault", %{action: "fly"})) =~ "action must be one of"

    assert error!(call(conn, "manage_vault", %{action: "rename", vault: "Nope", name: "x"})) =~
             "vault"

    assert error!(call(conn, "list_vaults", %{path: "/x"})) =~ "which vault"

    call(conn, "manage_vault", %{action: "create", name: "Notes"})

    assert error!(call(conn, "manage_vault", %{action: "map", vault: "Notes"})) =~
             "board is required"

    assert error!(call(conn, "manage_vault", %{action: "map", vault: "Notes", board: "nope"})) =~
             "board"

    assert error!(call(conn, "list_vaults", %{vault: "Notes", path: "/x.md"})) =~ "mapping"
  end

  test "a read-only token may list but not change", %{user: user} do
    {:ok, _} = Vaults.create_vault(user, %{"name" => "Notes"})
    {token, _} = Accounts.create_api_token(user, "reader", scope: "read")
    conn = build_conn() |> put_req_header("authorization", "Bearer " <> token)

    assert [_] = ok!(call(conn, "list_vaults", %{}))["vaults"]
    assert error!(call(conn, "manage_vault", %{action: "create", name: "More"})) =~ "read-only"
  end

  test "list_vaults resolves a link, page_info lists a vault's wanted pages", %{
    conn: conn,
    user: user
  } do
    {:ok, vault} = Vaults.create_vault(user, %{"name" => "Notes"})
    {:ok, kb} = Slipdock.Access.find_board(user, "kb")
    {:ok, jobs} = Slipdock.Access.find_board(user, "jobs")
    {:ok, _} = Vaults.add_mapping(vault, user, %{path: "/", board: kb})
    {:ok, _} = Vaults.add_mapping(vault, user, %{path: "/Jobs", board: jobs})
    {:ok, note} = Slipdock.Wiki.create_page(jobs, %{"title" => "Acme"}, user: user)
    {:ok, _} = Slipdock.Wiki.create_page(kb, %{"title" => "L", "body" => "[[Ghost]]"}, user: user)

    found = ok!(call(conn, "list_vaults", %{vault: "Notes", link: "Acme"}))
    assert found["page"]["code"] == note.code
    assert found["path"] == "/Jobs/Acme"
    assert error!(call(conn, "list_vaults", %{link: "Acme"})) =~ "which vault"

    wanted = ok!(call(conn, "page_info", %{what: "wanted", vault: "Notes"}))
    assert [%{"title" => "Ghost"}] = wanted["wanted"]
  end

  test "list_vaults gives the change feed after a cursor", %{conn: conn, user: user} do
    {:ok, vault} = Vaults.create_vault(user, %{"name" => "Notes"})
    {:ok, kb} = Slipdock.Access.find_board(user, "kb")
    {:ok, _} = Vaults.add_mapping(vault, user, %{path: "/", board: kb})
    {:ok, _} = Slipdock.Wiki.create_page(kb, %{"title" => "Fresh"}, user: user)

    feed = ok!(call(conn, "list_vaults", %{vault: "Notes", changes_since: 0}))
    assert Enum.any?(feed["changes"], &(&1["title"] == "Fresh"))
    assert is_integer(feed["cursor"])
    assert error!(call(conn, "list_vaults", %{vault: "Notes", changes_since: -1})) =~ "cursor"
    assert error!(call(conn, "list_vaults", %{changes_since: 0})) =~ "vault"
  end
end
