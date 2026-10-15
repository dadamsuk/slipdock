defmodule SlipdockWeb.API.GrantsTest do
  @moduledoc "Sharing pages and folders over the API, and what is shared with you (#820)."
  use SlipdockWeb.ConnCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Access, Accounts, Wiki}

  setup %{conn: conn, user: owner} do
    board = board_fixture(%{"name" => "Handbook"}, owner: owner)
    {:ok, folder} = Wiki.create_folder(board, %{"name" => "Specs"})
    page = page_fixture(board, %{"title" => "Plan", "folder_id" => folder.id}, user: owner)
    friend = user_fixture("friend@example.com")

    %{
      conn: put_req_header(conn, "accept", "application/json"),
      owner: owner,
      board: board,
      folder: folder,
      page: page,
      friend: friend
    }
  end

  defp as(user), do: user |> conn_as() |> put_req_header("accept", "application/json")

  describe "a page's grants" do
    test "are shared, changed, listed and taken back by the owner", c do
      assert %{"grant" => %{"level" => "read", "user" => %{"email" => email}}} =
               c.conn
               |> post("/api/pages/#{c.page.code}/grants", %{email: c.friend.email, level: "read"})
               |> json_response(201)

      assert email == c.friend.email
      assert Access.page_permission(c.friend, c.page) == :read

      c.conn
      |> post("/api/pages/#{c.page.id}/grants", %{email: c.friend.email, level: "write"})
      |> json_response(201)

      assert %{"grants" => [%{"level" => "write"}]} =
               c.conn |> get("/api/pages/#{c.page.id}/grants") |> json_response(200)

      assert %{"revoked" => true} =
               c.conn
               |> delete("/api/pages/#{c.page.id}/grants", %{email: c.friend.email})
               |> json_response(200)

      assert Access.page_permission(c.friend, c.page) == :none
    end

    test "go to a group by name", c do
      {:ok, group} = Accounts.create_group(c.owner, %{"name" => "Ops"})
      {:ok, _} = Accounts.add_group_member(group, c.friend.email)

      assert %{"grant" => %{"group" => %{"name" => "Ops"}}} =
               c.conn
               |> post("/api/pages/#{c.page.id}/grants", %{group: "ops", level: "write"})
               |> json_response(201)

      assert Access.page_permission(c.friend, c.page) == :write

      c.conn |> delete("/api/pages/#{c.page.id}/grants", %{group: group.id}) |> json_response(200)
      assert Access.page_permission(c.friend, c.page) == :none
    end

    test "say what is wrong with a bad request", c do
      assert %{"error" => "say who: an email or a group"} =
               c.conn
               |> post("/api/pages/#{c.page.id}/grants", %{level: "read"})
               |> json_response(400)

      assert %{"error" => "level is read or write"} =
               c.conn
               |> post("/api/pages/#{c.page.id}/grants", %{email: c.friend.email, level: "admin"})
               |> json_response(400)

      c.conn
      |> delete("/api/pages/#{c.page.id}/grants", %{email: "nobody-here@example.com"})
      |> json_response(404)
    end
  end

  describe "refused" do
    test "for somebody it was shared with, even to edit: they can't pass it on", c do
      {:ok, _} = Access.grant(c.page, c.friend, "write", c.owner)
      stranger = user_fixture("stranger@example.com")

      assert %{"error" => "shared_no_reshare"} =
               c.friend
               |> as()
               |> post("/api/pages/#{c.page.id}/grants", %{email: stranger.email, level: "read"})
               |> json_response(403)

      assert %{"error" => "shared_no_reshare"} =
               c.friend |> as() |> get("/api/pages/#{c.page.id}/grants") |> json_response(403)

      assert %{"error" => "shared_no_reshare"} =
               c.friend
               |> as()
               |> delete("/api/pages/#{c.page.id}/grants", %{email: c.friend.email})
               |> json_response(403)

      assert Access.page_permission(stranger, c.page) == :none
    end

    test "for a reader of the board who isn't its writer", c do
      reader = user_fixture("reader@example.com")
      {:ok, _} = Access.grant(c.board, reader, "read", c.owner)

      assert %{"error" => "forbidden: you don't edit its board"} =
               reader
               |> as()
               |> post("/api/folders/#{c.folder.id}/grants", %{email: c.friend.email})
               |> json_response(403)
    end

    test "as not found for somebody who can't see it", c do
      stranger = user_fixture("stranger@example.com")

      stranger |> as() |> get("/api/pages/#{c.page.id}/grants") |> json_response(404)
      stranger |> as() |> get("/api/folders/#{c.folder.id}/grants") |> json_response(404)
    end
  end

  test "a folder's grants share what is in it", c do
    c.conn
    |> post("/api/folders/#{c.folder.id}/grants", %{email: c.friend.email, level: "write"})
    |> json_response(201)

    assert Access.page_permission(c.friend, c.page) == :write

    assert %{"grants" => [%{"user" => %{"email" => _}}]} =
             c.conn |> get("/api/folders/#{c.folder.id}/grants") |> json_response(200)

    c.conn
    |> delete("/api/folders/#{c.folder.id}/grants", %{email: c.friend.email})
    |> json_response(200)

    assert Access.page_permission(c.friend, c.page) == :none
  end

  test "GET /api/shared is the Shared with me tree, grouped by owner", c do
    assert %{"shared" => []} = c.friend |> as() |> get("/api/shared") |> json_response(200)

    {:ok, _} = Access.grant(c.folder, c.friend, "read", c.owner)

    assert %{"shared" => [%{"owner" => owner, "items" => [folder]}]} =
             c.friend |> as() |> get("/api/shared") |> json_response(200)

    assert owner["id"] == c.owner.id
    assert folder["kind"] == "folder" and folder["name"] == "Specs"
    assert [%{"title" => "Plan", "code" => code, "url" => url}] = folder["pages"]
    assert code == c.page.code and url == "/shared/pages/#{c.page.id}"
  end

  test "a shared page reads and edits by its code like any other", c do
    {:ok, _} = Access.grant(c.page, c.friend, "write", c.owner)

    assert %{"page" => %{"title" => "Plan"}} =
             c.friend |> as() |> get("/api/pages/#{c.page.code}") |> json_response(200)

    assert %{"page" => %{"body" => "Edited."}} =
             c.friend
             |> as()
             |> patch("/api/pages/#{c.page.code}", %{body: "Edited."})
             |> json_response(200)
  end
end
