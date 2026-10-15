defmodule SlipdockWeb.API.SharedWritesTest do
  @moduledoc """
  A read-write sharee over the API (#816): what a folder or page share lets
  them do, and the 403s, each with its reason, for what it doesn't.
  """
  use SlipdockWeb.ConnCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Access, Settings, Wiki}

  setup %{user: owner} do
    board = board_fixture(%{"name" => "Handbook"}, owner: owner)
    {:ok, shared} = Wiki.create_folder(board, %{"name" => "Shared"})
    {:ok, inner} = Wiki.create_folder(board, %{"name" => "Inner", "parent_id" => shared.id})
    {:ok, private} = Wiki.create_folder(board, %{"name" => "Private"})
    page = page_fixture(board, %{"title" => "Plan", "folder_id" => inner.id}, user: owner)
    sharee = user_fixture("sharee@example.com")
    {:ok, _} = Access.grant(shared, sharee, "write", owner)

    conn = sharee |> conn_as() |> put_req_header("accept", "application/json")

    %{
      sharee_conn: conn,
      sharee: sharee,
      board: board,
      shared: shared,
      inner: inner,
      private: private,
      page: page
    }
  end

  describe "allowed" do
    test "editing and renaming a shared page", c do
      body =
        c.sharee_conn
        |> patch("/api/pages/#{c.page.id}", %{title: "Plan B", body: "Changed."})
        |> json_response(200)

      assert body["page"]["title"] == "Plan B"
      assert Wiki.get_page!(c.page.id).body == "Changed."
    end

    test "making a page in a shared folder: the owner's, made by the sharee", c do
      body =
        c.sharee_conn
        |> post("/api/folders/#{c.inner.id}/pages", %{title: "Mine", body: "Hello"})
        |> json_response(201)

      page = Wiki.get_page!(body["page"]["id"])
      assert page.board_id == c.board.id
      assert page.folder_id == c.inner.id
      assert page.created_by_id == c.sharee.id
    end

    test "making and renaming a subfolder, and moving within the share", c do
      %{"folder" => %{"id" => id}} =
        c.sharee_conn
        |> post("/api/folders/#{c.inner.id}/folders", %{name: "Sub"})
        |> json_response(201)

      assert Wiki.get_folder(id).parent_id == c.inner.id

      assert %{"folder" => %{"name" => "Renamed"}} =
               c.sharee_conn
               |> patch("/api/folders/#{id}", %{name: "Renamed"})
               |> json_response(200)

      assert c.sharee_conn
             |> patch("/api/folders/#{id}", %{parent: c.shared.id})
             |> json_response(200)

      assert Wiki.get_folder(id).parent_id == c.shared.id

      assert c.sharee_conn
             |> post("/api/pages/#{c.page.id}/folder", %{folder: c.shared.id})
             |> json_response(200)

      assert Wiki.get_page!(c.page.id).folder_id == c.shared.id
    end

    test "reading the shared folder by id", c do
      assert %{"folder" => %{"name" => "Inner"}} =
               c.sharee_conn |> get("/api/folders/#{c.inner.id}") |> json_response(200)
    end
  end

  describe "refused, with a reason" do
    test "archiving, restoring and deleting a page", c do
      assert %{"error" => "shared_no_delete", "message" => _} =
               c.sharee_conn |> delete("/api/pages/#{c.page.id}") |> json_response(403)

      assert %{"error" => "shared_no_delete"} =
               c.sharee_conn |> post("/api/pages/#{c.page.id}/restore") |> json_response(403)

      refute Wiki.get_page!(c.page.id).archived_at
    end

    test "deleting a folder", c do
      assert %{"error" => "shared_no_delete"} =
               c.sharee_conn |> delete("/api/folders/#{c.inner.id}") |> json_response(403)

      assert Wiki.get_folder(c.inner.id)
    end

    test "moving a page out of the share or to the top", c do
      assert %{"error" => "shared_no_move_out"} =
               c.sharee_conn
               |> post("/api/pages/#{c.page.id}/folder", %{folder: c.private.id})
               |> json_response(403)

      assert %{"error" => "shared_no_move_out"} =
               c.sharee_conn
               |> patch("/api/pages/#{c.page.id}", %{folder: "root"})
               |> json_response(403)

      assert Wiki.get_page!(c.page.id).folder_id == c.inner.id
    end

    test "filing a page in a folder that doesn't exist makes none on the owner's board", c do
      before = length(Wiki.folders(c.board))

      assert %{"error" => "shared_no_create"} =
               c.sharee_conn
               |> patch("/api/pages/#{c.page.id}", %{folder: "Brand new"})
               |> json_response(403)

      assert length(Wiki.folders(c.board)) == before
    end

    test "moving a folder out of the share, or the shared folder itself", c do
      assert %{"error" => "shared_no_move_out"} =
               c.sharee_conn
               |> patch("/api/folders/#{c.inner.id}", %{parent: c.private.id})
               |> json_response(403)

      assert %{"error" => "shared_no_move"} =
               c.sharee_conn
               |> patch("/api/folders/#{c.shared.id}", %{parent: c.private.id})
               |> json_response(403)
    end

    test "moving a page to a board of the sharee's own", c do
      theirs = board_fixture(%{"name" => "Theirs"}, owner: c.sharee)

      assert %{"error" => "shared_no_move_out"} =
               c.sharee_conn
               |> post("/api/pages/#{c.page.id}/move", %{board: theirs.code})
               |> json_response(403)
    end

    test "publishing it at a public link", c do
      assert %{"error" => "shared_no_reshare"} =
               c.sharee_conn |> post("/api/pages/#{c.page.id}/publish") |> json_response(403)

      refute Wiki.get_page!(c.page.id).public_token
    end

    test "making a page outside the share: the folder isn't theirs to see", c do
      c.sharee_conn
      |> post("/api/folders/#{c.private.id}/pages", %{title: "Sneaky"})
      |> json_response(404)

      c.sharee_conn
      |> post("/api/boards/#{c.board.id}/pages", %{title: "Sneaky"})
      |> json_response(404)
    end

    test "a reader of the share writes nothing", c do
      reader = user_fixture("reader@example.com")

      {:ok, _} =
        Access.grant(
          c.shared,
          reader,
          "read",
          Slipdock.Repo.get!(Slipdock.Accounts.User, c.board.owner_id)
        )

      conn = reader |> conn_as() |> put_req_header("accept", "application/json")

      assert %{"error" => "forbidden: " <> _} =
               conn
               |> post("/api/folders/#{c.inner.id}/pages", %{title: "x"})
               |> json_response(403)

      assert %{"error" => "forbidden: " <> _} =
               conn |> patch("/api/pages/#{c.page.id}", %{title: "x"}) |> json_response(403)
    end
  end

  test "a page made by a sharee counts against the owner's account: 402 for the owner's limit",
       c do
    {:ok, _} =
      Settings.complete_setup(%{"admin_email" => "admin@example.com", "free_card_limit" => 1})

    body =
      c.sharee_conn
      |> post("/api/folders/#{c.inner.id}/pages", %{title: "One too many"})
      |> json_response(402)

    assert body["error"] == "card_limit_reached"
    assert body["message"] =~ "board's owner"
    refute Enum.any?(Wiki.list_pages(c.board), &(&1.title == "One too many"))
  end
end
