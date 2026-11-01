defmodule SlipdockWeb.API.VaultSyncDressTest do
  @moduledoc """
  What the sync listing says beyond files and hashes (#1584): what rows wear,
  what the reader may do with them, and how a change of dress reaches a client.
  """
  use SlipdockWeb.ConnCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Access, Accounts, Vaults, Wiki}
  alias Slipdock.Wiki.{Files, Folders}
  alias SlipdockWeb.API.JSON, as: V

  setup %{conn: conn, user: user} do
    board = board_fixture(%{"name" => "Dressed", "code" => "dr15"}, owner: user)
    {:ok, vault} = Vaults.create_vault(user, %{"name" => "Wardrobe"})
    {:ok, _} = Vaults.add_mapping(vault, user, %{path: "/", board: board})
    %{conn: put_req_header(conn, "accept", "application/json"), board: board, vault: vault}
  end

  defp listing(conn), do: conn |> get("/api/vaults/Wardrobe/sync") |> json_response(200)

  defp with_token(conn, user, opts) do
    {token, _} = Accounts.create_api_token(user, "dress", opts)

    conn
    |> Plug.Conn.delete_req_header("cookie")
    |> recycle()
    |> put_req_header("accept", "application/json")
    |> put_req_header("authorization", "Bearer " <> token)
  end

  defp entry(listing, path), do: Enum.find(listing["entries"], &(&1["path"] == path))

  defp file(board, user, name) do
    source = Path.join(System.tmp_dir!(), "dress-#{System.unique_integer([:positive])}")
    File.write!(source, "bytes")
    on_exit(fn -> File.rm(source) end)
    {:ok, file} = Files.create(board, %{name: name, folder_id: nil}, source, user)
    file
  end

  describe "pages and folders" do
    test "wear their icon and colour; plain ones say nil", %{conn: conn, board: board} do
      {:ok, _} = Wiki.create_page(board, %{"title" => "Plain"})
      {:ok, page} = Wiki.create_page(board, %{"title" => "Worn"})
      {:ok, _} = Wiki.update_page(page, %{"icon" => "star", "color" => "rose"})
      {:ok, plain} = Wiki.create_folder(board, %{"name" => "Bare"})
      {:ok, worn} = Wiki.create_folder(board, %{"name" => "Fancy"})
      {:ok, _} = Folders.update(worn, %{"icon" => "bolt", "color" => "teal"})

      body = listing(conn)

      assert %{"icon" => "star", "color" => "rose"} = entry(body, "Worn.md")
      assert %{"icon" => nil, "color" => nil} = entry(body, "Plain.md")

      assert body["folders"] == ["Bare", "Fancy"]

      assert %{
               "Bare" => %{"id" => bare_id, "icon" => nil, "color" => nil},
               "Fancy" => %{"id" => worn_id, "icon" => "bolt", "color" => "teal"}
             } = body["folder_details"]

      assert bare_id == plain.id
      assert worn_id == worn.id
      assert body["folder_details"]["Fancy"]["board_id"] == board.id
    end

    test "a mapped subfolder is keyed by its vault path, not its board path", ctx do
      board = board_fixture(%{"name" => "Studio", "code" => "dr19"}, owner: ctx.user)
      {:ok, design} = Wiki.create_folder(board, %{"name" => "Design"})
      {:ok, old} = Wiki.create_folder(board, %{"name" => "Old", "parent_id" => design.id})
      {:ok, vault} = Vaults.create_vault(ctx.user, %{"name" => "Mapped"})

      {:ok, _} =
        Vaults.add_mapping(vault, ctx.user, %{path: "/Work", board: board, folder: design})

      body = ctx.conn |> get("/api/vaults/Mapped/sync") |> json_response(200)

      assert %{"Work" => work, "Work/Old" => %{"id" => old_id}} = body["folder_details"]
      assert work["id"] == design.id
      assert old_id == old.id
      assert body["folders"] == ["Work", "Work/Old"]
      refute Map.has_key?(body["folder_details"], "Design/Old")
    end

    test "a folder mapped at the root is the root, so no details", ctx do
      board = board_fixture(%{"name" => "Rooted", "code" => "dr20"}, owner: ctx.user)
      {:ok, folder} = Wiki.create_folder(board, %{"name" => "Rooted"})
      {:ok, vault} = Vaults.create_vault(ctx.user, %{"name" => "AtRoot"})

      {:ok, _} = Vaults.add_mapping(vault, ctx.user, %{path: "/", board: board, folder: folder})

      body = ctx.conn |> get("/api/vaults/AtRoot/sync") |> json_response(200)

      assert body["folder_details"] == %{}
      assert body["folders"] == []
    end
  end

  describe "writable and shareable" do
    setup %{board: board, user: user} do
      {:ok, _} = Wiki.create_page(board, %{"title" => "Note"})
      {:ok, _} = Wiki.create_folder(board, %{"name" => "Box"})
      file(board, user, "photo.png")
      :ok
    end

    defp rights(row), do: {row["writable"], row["shareable"]}

    test "an owner may do both, but a file is not shared", %{conn: conn} do
      body = listing(conn)

      assert rights(entry(body, "Note.md")) == {true, true}
      assert rights(body["folder_details"]["Box"]) == {true, true}
      assert rights(entry(body, "photo.png")) == {true, false}
    end

    test "a read-only token may do neither", %{conn: conn, user: user} do
      body = conn |> with_token(user, scope: "read") |> listing()

      assert rights(entry(body, "Note.md")) == {false, false}
      assert rights(body["folder_details"]["Box"]) == {false, false}
      assert rights(entry(body, "photo.png")) == {false, false}
    end

    test "a token limited to another board sees none of this one", ctx do
      other = board_fixture(%{"name" => "Other", "code" => "dr16"}, owner: ctx.user)
      {:ok, _} = Wiki.create_page(other, %{"title" => "Elsewhere"})
      {:ok, _} = Vaults.add_mapping(ctx.vault, ctx.user, %{path: "/Other", board: other})

      body = ctx.conn |> with_token(ctx.user, scope_boards: [other.id]) |> listing()

      assert [%{"path" => "Other/Elsewhere.md"} = page] = body["entries"]
      assert rights(page) == {true, true}
      assert body["folder_details"] == %{}
      assert body["folders"] == []
    end

    test "a reader of a mapped board may do neither there, and keeps their own", ctx do
      owner = user_fixture("dress-owner@example.com")
      theirs = board_fixture(%{"name" => "Theirs", "code" => "dr17"}, owner: owner)
      {:ok, _} = Wiki.create_page(theirs, %{"title" => "Lent"})
      {:ok, _} = Wiki.create_folder(theirs, %{"name" => "Shelf"})

      # A mapping takes write, so they lose it after mapping the board.
      {:ok, _} = Access.grant(theirs, ctx.user, "write", owner)
      {:ok, _} = Vaults.add_mapping(ctx.vault, ctx.user, %{path: "/Theirs", board: theirs})
      {:ok, _} = Access.grant(theirs, ctx.user, "read", owner)

      body = listing(ctx.conn)

      assert rights(entry(body, "Theirs/Lent.md")) == {false, false}
      assert rights(body["folder_details"]["Theirs/Shelf"]) == {false, false}
      assert rights(entry(body, "Note.md")) == {true, true}
    end
  end

  test "stubs carry none of it, and their directories no details", ctx do
    owner = user_fixture("stub-owner@example.com")
    theirs = board_fixture(%{"name" => "Lender", "code" => "dr18"}, owner: owner)
    plan = page_fixture(theirs, %{"title" => "Plan"}, user: owner)
    {:ok, _} = Wiki.update_page(plan, %{"icon" => "star"})
    {:ok, inbox} = Wiki.create_folder(ctx.board, %{"name" => "Inbox"})
    {:ok, _} = Access.grant(plan, ctx.user, "read", owner)
    {:ok, _} = Wiki.Placements.add(plan, inbox, ctx.user)

    body = ctx.conn |> get("/api/vaults/Wardrobe/sync?stubs=1") |> json_response(200)

    assert [stub] = Enum.filter(body["entries"], &(&1["kind"] == "stub"))
    for key <- ~w(icon color writable shareable), do: refute(Map.has_key?(stub, key))
  end

  describe "the change feed" do
    test "a page's new dress is a change, and leaves its hashes alone", %{conn: conn} = ctx do
      {:ok, page} = Wiki.create_page(ctx.board, %{"title" => "Note", "body" => "words"})
      %{"hash" => hash} = conn |> listing() |> entry("Note.md")
      %{"cursor" => start} = conn |> get("/api/vaults/Wardrobe/changes") |> json_response(200)

      {:ok, _} = Wiki.update_page(page, %{"icon" => "fire", "color" => "amber"})

      body = conn |> get("/api/vaults/Wardrobe/changes?since=#{start}") |> json_response(200)

      assert [%{"subject" => "page", "action" => "changed"} = change] = body["changes"]
      assert change["id"] == page.id
      assert %{"icon" => "fire", "color" => "amber"} = change
      assert change["content_hash"] == page.content_hash

      assert %{"hash" => ^hash, "icon" => "fire"} = conn |> listing() |> entry("Note.md")
    end

    test "so does a folder's", %{conn: conn, board: board} do
      {:ok, folder} = Wiki.create_folder(board, %{"name" => "Box"})
      %{"cursor" => start} = conn |> get("/api/vaults/Wardrobe/changes") |> json_response(200)

      {:ok, _} = Folders.update(folder, %{"icon" => "cube", "color" => "sky"})

      body = conn |> get("/api/vaults/Wardrobe/changes?since=#{start}") |> json_response(200)

      assert [%{"subject" => "folder", "icon" => "cube", "color" => "sky"} = change] =
               body["changes"]

      assert change["id"] == folder.id
    end
  end

  describe "the vault and its boards" do
    test "the vault says it is the reader's, and each board's switch", ctx do
      assert %{"vault" => %{"owned" => true, "mappings" => [mapping]}} =
               ctx.conn |> get("/api/vaults/Wardrobe") |> json_response(200)

      assert mapping["board"]["wiki_tree_icons"] == true

      {:ok, _} = Wiki.set_tree_icons(ctx.board, false)

      assert %{"vault" => %{"mappings" => [%{"board" => %{"wiki_tree_icons" => false}}]}} =
               ctx.conn |> get("/api/vaults/Wardrobe") |> json_response(200)

      assert %{"vaults" => [%{"owned" => true}]} =
               ctx.conn |> get("/api/vaults") |> json_response(200)
    end

    test "somebody else reading it is told it isn't theirs", ctx do
      {:ok, vault} = Vaults.get_vault(ctx.user, "Wardrobe")

      assert V.vault(vault, ctx.user).owned
      refute V.vault(vault, user_fixture("not-the-owner@example.com")).owned
    end

    test "a board says whether its tree wears icons", %{conn: conn, board: board} do
      {:ok, _} = Wiki.set_tree_icons(board, false)

      assert %{"board" => %{"wiki_tree_icons" => false}} =
               conn |> get("/api/boards/#{board.id}") |> json_response(200)
    end
  end
end
