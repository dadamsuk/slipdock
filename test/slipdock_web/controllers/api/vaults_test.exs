defmodule SlipdockWeb.API.VaultsTest do
  @moduledoc "`/api/vaults`: the caller's root vault over HTTP, and what went with mounting."
  use SlipdockWeb.ConnCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Accounts, Boards, Vaults, Wiki}

  setup %{conn: conn, user: user} do
    kb = board_fixture(%{"name" => "Keystone", "code" => "kb5"}, owner: user)
    jobs = board_fixture(%{"name" => "Journal Desk", "code" => "jobs4"}, owner: user)
    {:ok, _} = Wiki.create_folder(jobs, %{"name" => "Notes"})
    {:ok, vault} = user |> Vaults.root() |> Vaults.update_vault(%{"name" => "Notes"})

    %{conn: put_req_header(conn, "accept", "application/json"), kb: kb, jobs: jobs, vault: vault}
  end

  defp show(conn),
    do: conn |> get("/api/vaults/Notes") |> json_response(200) |> Map.fetch!("vault")

  test "the list is the one vault, with every board in it", %{conn: conn, vault: vault} do
    id = vault.id

    assert [%{"id" => ^id, "name" => "Notes", "boards" => boards}] =
             conn |> get("/api/vaults") |> json_response(200) |> Map.fetch!("vaults")

    assert [
             %{"path" => "/Journal Desk", "code" => "jobs4", "archived" => false},
             %{"path" => "/Keystone", "code" => "kb5", "archived" => false}
           ] = boards
  end

  test "an archived board isn't among its boards; restored, it is again", %{conn: conn, kb: kb} do
    {:ok, kb} = Boards.archive_board(kb)
    refute Enum.find(show(conn)["boards"], &(&1["code"] == "kb5"))

    {:ok, _} = Boards.unarchive_board(kb)

    assert %{"path" => "/Keystone", "archived" => false} =
             Enum.find(show(conn)["boards"], &(&1["code"] == "kb5"))
  end

  test "a vault shows its page count, its address and the tokens that synced it", ctx do
    %{conn: conn, kb: kb, vault: vault} = ctx
    {:ok, _} = Wiki.create_page(kb, %{"title" => "Note"})

    shown = show(conn)
    assert shown["pages"] == 1
    assert shown["id"] == vault.id
    assert shown["owned"] == true
    assert shown["shortcut"] == vault.shortcut
    assert shown["url"] == "/wiki"
    assert shown["mirrors"] == []
    assert Map.has_key?(shown, "recordings_folder")
    refute Map.has_key?(shown, "mappings")
    refute Map.has_key?(shown, "overlaps")

    # Listing it for a sync, or following its feed, marks the token a mirror.
    conn |> get("/api/vaults/Notes/sync") |> json_response(200)
    conn |> get("/api/vaults/Notes/changes") |> json_response(200)

    assert [%{"label" => "test", "last_synced_at" => _}] = show(conn)["mirrors"]
  end

  test "the listing says each board's path, and leaves an archived one out", ctx do
    assert %{"boards" => boards} =
             ctx.conn |> get("/api/vaults/Notes/sync") |> json_response(200)

    assert [
             %{"path" => "Journal Desk", "archived" => false},
             %{"path" => "Keystone", "archived" => false}
           ] = Enum.sort_by(boards, & &1["path"])

    {:ok, _} = Boards.archive_board(ctx.kb)

    assert %{"boards" => [%{"path" => "Journal Desk"}], "folders" => folders} =
             ctx.conn |> get("/api/vaults/Notes/sync") |> json_response(200)

    refute "Keystone" in folders
  end

  test "renames it, by id or name; a bad name is a 422", %{conn: conn, vault: vault} do
    assert %{"vault" => %{"name" => "Brain"}} =
             conn |> patch("/api/vaults/#{vault.id}", %{"name" => "Brain"}) |> json_response(200)

    assert conn |> get("/api/vaults/Notes") |> json_response(404)
    assert conn |> patch("/api/vaults/brain", %{"name" => "a/b"}) |> json_response(422)
  end

  test "sets its shortcut and hotkey; a digit that isn't one changes nothing", ctx do
    %{conn: conn, user: user, vault: vault} = ctx

    assert %{"vault" => %{"shortcut" => "qv", "hotkey" => 4}} =
             conn
             |> patch("/api/vaults/Notes", %{"shortcut" => "qv", "hotkey" => 4})
             |> json_response(200)

    assert conn
           |> patch("/api/vaults/Notes", %{"name" => "Lost", "hotkey" => "x"})
           |> json_response(422)

    assert {:ok, %{name: "Notes"}} = Vaults.get_vault(user, vault.id)
  end

  test "setting a recordings folder needs Drive connected", %{conn: conn} do
    assert %{"error" => error} =
             conn
             |> patch("/api/vaults/Notes", %{"recordings_folder" => "Calls"})
             |> json_response(409)

    assert error =~ "Google Drive"

    assert %{"vault" => %{"recordings_folder" => nil}} =
             conn
             |> patch("/api/vaults/Notes", %{"recordings_folder" => ""})
             |> json_response(200)
  end

  describe "locate" do
    test "answers with the board and the rest of the path", ctx do
      located =
        ctx.conn
        |> get("/api/vaults/#{ctx.vault.id}/locate?path=/Journal Desk/Acme/Call.md")
        |> json_response(200)

      assert located["board"]["id"] == ctx.jobs.id
      assert located["board"]["path"] == "/Journal Desk"
      assert located["rest"] == "Acme/Call.md"
      refute Map.has_key?(located, "mapping")
    end

    test "the root, no such board, and a climb are refused", %{conn: conn} do
      assert conn |> get("/api/vaults/Notes/locate?path=/") |> json_response(404)
      assert conn |> get("/api/vaults/Notes/locate") |> json_response(404)
      assert conn |> get("/api/vaults/Notes/locate?path=/x.md") |> json_response(404)
      assert conn |> get("/api/vaults/Notes/locate?path=/Nope/x.md") |> json_response(404)
      assert conn |> get("/api/vaults/Notes/locate?path=/Keystone/../x") |> json_response(422)
    end
  end

  test "somebody else's vault is not there", %{user: user} do
    stranger = user_fixture("stranger@example.com")
    {:ok, vault} = stranger |> Vaults.root() |> Vaults.update_vault(%{"name" => "Private"})

    conn = conn_as(user) |> put_req_header("accept", "application/json")
    assert conn |> get("/api/vaults/#{vault.id}") |> json_response(404)
    assert conn |> patch("/api/vaults/#{vault.id}", %{"name" => "Mine"}) |> json_response(404)
    assert conn |> get("/api/vaults/#{vault.id}/locate?path=/x") |> json_response(404)
    assert {:ok, %{name: "Private"}} = Vaults.get_vault(stranger, vault.id)
  end

  test "a read-only token reads the vault and changes nothing", %{user: user} do
    {token, _} = Accounts.create_api_token(user, "reader", scope: "read")

    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer " <> token)
      |> put_req_header("accept", "application/json")

    assert conn |> get("/api/vaults") |> json_response(200)
    assert conn |> patch("/api/vaults/Notes", %{"name" => "More"}) |> json_response(403)
  end

  test "resolve a link and list what is wanted, across the vault", ctx do
    %{conn: conn, user: user, kb: kb, jobs: jobs} = ctx
    {:ok, note} = Wiki.create_page(jobs, %{"title" => "Acme"}, user: user)

    {:ok, _} =
      Wiki.create_page(kb, %{"title" => "Linker", "body" => "[[Acme]] [[Ghost]]"}, user: user)

    found = conn |> get("/api/vaults/Notes/resolve?link=Journal Desk/Acme") |> json_response(200)
    assert found["page"]["code"] == note.code
    assert found["path"] == "/Journal Desk/Acme"

    assert conn |> get("/api/vaults/Notes/resolve?link=Nope") |> json_response(404)
    assert conn |> get("/api/vaults/Notes/resolve") |> json_response(400)

    assert [%{"title" => "Ghost", "from" => [%{"title" => "Linker"}]}] =
             conn |> get("/api/vaults/Notes/wanted") |> json_response(200) |> Map.fetch!("wanted")
  end

  test "the change feed: a cursor to start from, then what changed", ctx do
    %{conn: conn, user: user, kb: kb} = ctx

    %{"changes" => [], "cursor" => start} =
      conn |> get("/api/vaults/Notes/changes") |> json_response(200)

    {:ok, page} = Wiki.create_page(kb, %{"title" => "Fresh"}, user: user)

    body = conn |> get("/api/vaults/Notes/changes?since=#{start}") |> json_response(200)

    assert [
             %{
               "subject" => "page",
               "id" => id,
               "path" => "Keystone/Fresh.md",
               "action" => "changed"
             }
           ] =
             body["changes"]

    assert id == page.id
    assert body["more"] == false

    assert conn |> get("/api/vaults/Notes/changes?since=-1") |> json_response(400)
    assert conn |> get("/api/vaults/Notes/changes?since=x") |> json_response(400)
    assert conn |> get("/api/vaults/Elsewhere/changes") |> json_response(404)
  end

  test "the board list says nothing of being kept inside a vault", %{conn: conn} do
    boards = conn |> get("/api/boards") |> json_response(200) |> Map.fetch!("boards")
    assert boards != []
    for board <- boards, do: refute(Map.has_key?(board, "inside_vault"))
  end

  describe "what went with mounting" do
    test "making and deleting a vault are gone", %{conn: conn, user: user, vault: vault} do
      assert conn |> post("/api/vaults", %{"name" => "More"}) |> json_response(404)
      assert conn |> delete("/api/vaults/#{vault.id}") |> json_response(404)
      assert [%{id: id}] = Vaults.list_vaults(user)
      assert id == vault.id
    end

    test "mappings are gone, every verb of them", %{conn: conn, vault: vault} do
      base = "/api/vaults/#{vault.id}/mappings"

      assert conn |> post(base, %{"board" => "kb5"}) |> json_response(404)
      assert conn |> delete(base <> "?path=/") |> json_response(404)
      assert conn |> delete(base <> "/1") |> json_response(404)
      assert conn |> patch(base, %{"path" => "/", "inside" => true}) |> json_response(404)
      assert conn |> patch(base <> "/1", %{"icon" => "star"}) |> json_response(404)
    end

    test "split is gone", %{conn: conn, vault: vault} do
      assert conn
             |> post("/api/vaults/#{vault.id}/split", %{"path" => "/Keystone", "new_board" => "X"})
             |> json_response(404)
    end
  end
end
