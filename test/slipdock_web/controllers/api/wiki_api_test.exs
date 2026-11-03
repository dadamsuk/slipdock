defmodule SlipdockWeb.API.WikiApiTest do
  @moduledoc """
  `/api/wiki/...` (W-2201): the caller's one wiki, which no address names.
  The same answers as `/api/vaults/:id/...`, which still answer so a client
  built against them keeps working until it moves; `GET /api/wiki` says what
  the wiki is beside every board's folders and pages, as it did.
  """
  use SlipdockWeb.ConnCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Vaults, Wiki}
  alias Slipdock.Wiki.KnowledgeBase

  setup %{conn: conn, user: user} do
    kb = board_fixture(%{"name" => "Keystone", "code" => "wakb"}, owner: user)
    {:ok, page} = Wiki.create_page(kb, %{"title" => "Plan", "body" => "Ship it."})
    vault = Vaults.root(user)

    %{conn: put_req_header(conn, "accept", "application/json"), kb: kb, page: page, vault: vault}
  end

  test "GET /api/wiki: what the wiki is, its Knowledge Base, and every board", ctx do
    %{conn: conn, user: user} = ctx
    body = conn |> get("/api/wiki") |> json_response(200)

    kb = KnowledgeBase.get(user)
    assert %{"wiki" => wiki, "boards" => boards} = body
    assert wiki["url"] == "/wiki"

    assert wiki["knowledge_base"] == %{
             "id" => kb.id,
             "code" => kb.code,
             "name" => "Knowledge Base"
           }

    refute Map.has_key?(wiki, "name")
    refute Map.has_key?(wiki, "id")

    assert Enum.map(wiki["boards"], & &1["path"]) |> Enum.sort() ==
             ["/Keystone", "/Knowledge Base"]

    assert Enum.any?(boards, &(&1["code"] == "wakb"))
  end

  test "PATCH /api/wiki sets its keys and answers as a wiki", %{conn: conn, vault: vault} do
    # A fixed key can be another running test's board's (#1637).
    key = unique_shortcut()

    assert %{"wiki" => %{"shortcut" => ^key}} =
             conn |> patch("/api/wiki", %{"shortcut" => key}) |> json_response(200)

    assert Vaults.root(vault.user_id).shortcut == key
  end

  test "its sync listing and feed are the vault's, by either address", ctx do
    %{conn: conn, vault: vault, page: page} = ctx

    wiki = conn |> get("/api/wiki/sync") |> json_response(200)
    old = conn |> get("/api/vaults/#{vault.id}/sync") |> json_response(200)

    assert Enum.map(wiki["entries"], & &1["path"]) == Enum.map(old["entries"], & &1["path"])
    assert Enum.any?(wiki["entries"], &(&1["id"] == page.id and &1["path"] == "Keystone/Plan.md"))

    assert %{"cursor" => _} = conn |> get("/api/wiki/changes") |> json_response(200)

    assert %{"board" => %{"path" => "/Keystone"}, "rest" => "Plan.md"} =
             conn
             |> get("/api/wiki/locate", %{"path" => "/Keystone/Plan.md"})
             |> json_response(200)
  end

  test "a page is written through /api/wiki/sync as through the vault's", ctx do
    %{conn: conn, page: page} = ctx

    assert %{"page" => %{"id" => id}} =
             conn
             |> put("/api/wiki/sync/pages/#{page.id}", %{
               "path" => "Keystone/Plan.md",
               "content" => "Shipped.",
               "base" => page.content_hash
             })
             |> json_response(200)

    assert id == page.id
    assert Wiki.get_page!(page.id).body == "Shipped."
  end

  test "a header link pins the wiki with wiki: true", %{conn: conn} do
    assert %{"header_link" => %{"wiki" => true}} =
             conn
             |> post("/api/header-links", %{"wiki" => true, "icon" => "book-open"})
             |> json_response(201)
  end

  test "with no user it is refused, as any API call is", %{conn: conn} do
    conn = conn |> delete_req_header("authorization") |> Plug.Conn.assign(:current_user, nil)
    assert conn |> get("/api/wiki/sync") |> response(401)
  end
end
