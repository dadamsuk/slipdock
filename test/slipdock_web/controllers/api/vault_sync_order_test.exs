defmodule SlipdockWeb.API.VaultSyncOrderTest do
  @moduledoc """
  What the sync listing says for a client to draw a directory in the web
  tree's order (#1585). `drawn/3` follows the rules in the API guide and
  knows nothing else, so each test holds it against `Wiki.Tree.children/3`.
  """
  use SlipdockWeb.ConnCase, async: true

  import Ecto.Query
  import Slipdock.Fixtures

  alias Slipdock.{Access, Accounts, Repo, Vaults, Wiki}
  alias Slipdock.Wiki.{FolderPlacements, Files, Folder, Folders, Page, Placements, Tree}

  setup %{conn: conn, user: user} do
    board = board_fixture(%{"name" => "Ordered", "code" => "or85"}, owner: user)
    {:ok, vault} = user |> Vaults.root() |> Vaults.update_vault(%{"name" => "Shelf"})
    %{conn: put_req_header(conn, "accept", "application/json"), board: board, vault: vault}
  end

  defp listing(conn), do: conn |> get("/api/vaults/Shelf/sync") |> json_response(200)
  defp vault_json(conn), do: conn |> get("/api/vaults/Shelf") |> json_response(200)
  defp boards_json(conn), do: vault_json(conn)["vault"]["boards"]

  defp with_token(conn, user, opts \\ []) do
    {token, _} = Accounts.create_api_token(user, "order", opts)

    conn
    |> Plug.Conn.delete_req_header("cookie")
    |> recycle()
    |> put_req_header("accept", "application/json")
    |> put_req_header("authorization", "Bearer " <> token)
  end

  defp file(board, user, name, folder_id \\ nil) do
    source = Path.join(System.tmp_dir!(), "order-#{System.unique_integer([:positive])}")
    File.write!(source, "bytes")
    on_exit(fn -> File.rm(source) end)
    {:ok, file} = Files.create(board, %{name: name, folder_id: folder_id}, source, user)
    file
  end

  defp entry(listing, path), do: Enum.find(listing["entries"], &(&1["path"] == path))

  defp page!(board, title, folder, position, inserted, updated) do
    {:ok, page} =
      Wiki.create_page(board, %{"title" => title, "folder_id" => folder && folder.id})

    {1, _} =
      from(p in Page, where: p.id == ^page.id)
      |> Repo.update_all(
        set: [
          position: position,
          inserted_at: DateTime.from_unix!(inserted),
          updated_at: DateTime.from_unix!(updated)
        ]
      )

    page.id
  end

  defp folder!(board, name, position, parent \\ nil) do
    {:ok, folder} =
      Wiki.create_folder(board, %{"name" => name, "parent_id" => parent && parent.id})

    {1, _} =
      from(f in Folder, where: f.id == ^folder.id) |> Repo.update_all(set: [position: position])

    Repo.get!(Folder, folder.id)
  end

  defp sort_of(details, board_sort), do: (details && details["sort"]) || board_sort

  # The rules of the API guide, on the listing alone, for one directory:
  # rows as {kind, id}.
  defp drawn(listing, dir, board_sort) do
    details = listing["folder_details"][dir]
    sort = sort_of(details, board_sort)
    in_dir = &(Path.dirname(&1) == if(dir == "", do: ".", else: dir))

    rows = listing["entries"] |> Enum.filter(&in_dir.(&1["path"]))

    also_pages = (details && details["also_pages"]) || []
    also_folders = (details && details["also_folders"]) || []

    home_folders =
      listing["folder_details"]
      |> Enum.filter(fn {path, _} -> in_dir.(path) end)
      |> Enum.map(fn {path, d} -> Map.put(d, "name", Path.basename(path)) end)
      |> Enum.sort_by(fn d ->
        if sort == "name",
          do: {String.downcase(d["name"]), d["id"]},
          else: {d["position"], String.downcase(d["name"]), d["id"]}
      end)

    pages = Enum.filter(rows, &(&1["kind"] == "page"))

    home_pages =
      case sort do
        "name" ->
          Enum.sort_by(pages, &{String.downcase(&1["title"]), &1["id"]})

        "manual" ->
          Enum.sort_by(pages, &{&1["position"], String.downcase(&1["title"]), &1["id"]})

        "modified" ->
          Enum.sort_by(pages, &{&1["updated_at"], &1["id"]}, :desc)

        "created" ->
          Enum.sort_by(pages, &{&1["inserted_at"], &1["id"]}, :desc)
      end

    files =
      rows
      |> Enum.filter(&(&1["kind"] == "file"))
      |> Enum.sort_by(&{String.downcase(&1["name"]), &1["id"]})

    Enum.map(home_folders, &{"folder", &1["id"]}) ++
      Enum.map(also_folders, &{"folder", &1}) ++
      Enum.map(home_pages, &{"page", &1["id"]}) ++
      Enum.map(also_pages, &{"page", &1}) ++
      Enum.map(files, &{"file", &1["id"]})
  end

  defp tree(board, ref) do
    board = Slipdock.Boards.get_board!(board.id)
    {:ok, rows} = Tree.children(board, ref)
    Enum.map(rows, &{&1.kind, &1.id})
  end

  describe "the fields" do
    test "a page says its position and the times the tree sorts on", %{conn: conn, board: board} do
      id = page!(board, "Dated", nil, 7, 1_000_000, 2_000_000)

      assert %{
               "position" => 7,
               "inserted_at" => "1970-01-12T13:46:40Z",
               "updated_at" => "1970-01-24T03:33:20Z"
             } = entry(listing(conn), "Ordered/Dated.md")

      assert Repo.get!(Page, id).updated_at == ~U[1970-01-24 03:33:20Z]
    end

    test "editing a page moves updated_at and not inserted_at", %{conn: conn, board: board} do
      id = page!(board, "Edited", nil, 0, 1_000_000, 2_000_000)
      {:ok, _} = Wiki.update_page(Repo.get!(Page, id), %{"body" => "New words"})

      row = entry(listing(conn), "Ordered/Edited.md")
      assert row["inserted_at"] == "1970-01-12T13:46:40Z"
      assert row["updated_at"] > "2020-01-01T00:00:00Z"
    end

    test "a write answers with them too", %{conn: conn} do
      answer =
        conn
        |> put("/api/vaults/Shelf/sync/pages", %{"path" => "Ordered/Fresh.md", "content" => "Hi"})
        |> json_response(200)

      assert %{"page" => %{"position" => position} = page} = answer
      assert is_integer(position)
      assert is_binary(page["inserted_at"]) and is_binary(page["updated_at"])
    end

    test "a file has times and no position", %{conn: conn, board: board, user: user} do
      file(board, user, "photo.png")

      row = entry(listing(conn), "Ordered/photo.png")
      assert Map.fetch!(row, "position") == nil
      assert is_binary(row["inserted_at"]) and is_binary(row["updated_at"])
    end

    test "a folder says its position, sort and times", %{conn: conn, board: board} do
      plain = folder!(board, "Plain", 3)
      {:ok, _} = Folders.update(folder!(board, "Sorted", 4), %{"sort" => "created"})

      details = listing(conn)["folder_details"]

      assert %{
               "id" => id,
               "position" => 3,
               "sort" => nil,
               "also_pages" => [],
               "also_folders" => []
             } = details["Ordered/Plain"]

      assert id == plain.id
      assert is_binary(details["Ordered/Plain"]["inserted_at"])
      assert is_binary(details["Ordered/Plain"]["updated_at"])
      assert %{"position" => 4, "sort" => "created"} = details["Ordered/Sorted"]
    end

    test "a stub carries none of them, and no order", %{conn: conn, board: board, user: user} do
      owner = user_fixture("order-stub@example.com")
      theirs = board_fixture(%{"name" => "Lender", "code" => "or86"}, owner: owner)
      plan = page_fixture(theirs, %{"title" => "Plan"}, user: owner)
      inbox = folder!(board, "Inbox", 0)
      {:ok, _} = Access.grant(plan, user, "read", owner)
      {:ok, _} = Placements.add(plan, inbox, user)

      body = conn |> get("/api/vaults/Shelf/sync?stubs=1") |> json_response(200)

      assert [stub] = Enum.filter(body["entries"], &(&1["kind"] == "stub"))
      for key <- ~w(position inserted_at updated_at), do: refute(Map.has_key?(stub, key))
      assert body["folder_details"]["Ordered/Inbox"]["also_pages"] == []
    end

    test "the change feed says them too", %{conn: conn, board: board, vault: vault} do
      cursor =
        get(conn, "/api/vaults/#{vault.id}/changes") |> json_response(200) |> Map.get("cursor")

      id = page!(board, "Fed", nil, 5, 1_000_000, 1_000_000)
      {:ok, _} = Wiki.update_page(Repo.get!(Page, id), %{"title" => "Fed again"})
      folder = folder!(board, "Fed folder", 2)
      {:ok, _} = Folders.update(folder, %{"sort" => "modified"})

      changes =
        conn
        |> get("/api/vaults/#{vault.id}/changes?since=#{cursor}")
        |> json_response(200)
        |> Map.fetch!("changes")

      page = Enum.find(changes, &(&1["subject"] == "page" and &1["id"] == id))
      assert page["position"] == 5
      assert page["inserted_at"] == "1970-01-12T13:46:40Z"

      row = Enum.find(changes, &(&1["subject"] == "folder" and &1["id"] == folder.id))
      assert %{"position" => 2, "sort" => "modified"} = row
    end
  end

  describe "which sort applies" do
    test "wiki_sort is on the vault's board, and is by name until chosen", %{
      conn: conn,
      board: board
    } do
      assert [%{"path" => "/Ordered", "wiki_sort" => "name"}] = boards_json(conn)
      assert tree(board, :root) == drawn(listing(conn), "Ordered", "name")
    end
  end

  describe "drawing a directory from the listing" do
    setup %{board: board} do
      a = page!(board, "alpha", nil, 2, 3000, 1000)
      b = page!(board, "Bravo", nil, 0, 1000, 3000)
      c = page!(board, "charlie", nil, 1, 2000, 2000)

      inside = folder!(board, "Inside", 1)
      page!(board, "one", inside, 1, 1000, 2000)
      page!(board, "Two", inside, 0, 2000, 1000)
      folder!(board, "zebra", 0)

      %{inside: inside, pages: [a, b, c]}
    end

    for sort <- ~w(manual name modified created) do
      test "the top, and a folder following it, by #{sort}", %{conn: conn, board: board} = ctx do
        {:ok, _} = Wiki.set_tree_sort(board, nil, unquote(sort))
        vault_sort = hd(boards_json(conn))["wiki_sort"]
        assert vault_sort == unquote(sort)

        shown = listing(conn)
        assert shown["folder_details"]["Ordered/Inside"]["sort"] == nil
        assert drawn(shown, "Ordered", vault_sort) == tree(board, :root)
        assert drawn(shown, "Ordered/Inside", vault_sort) == tree(board, {:folder, ctx.inside.id})
      end

      test "a folder by its own #{sort} under another top", %{conn: conn, board: board} = ctx do
        top = if unquote(sort) == "name", do: "created", else: "name"
        {:ok, _} = Wiki.set_tree_sort(board, nil, top)
        {:ok, _} = Folders.update(ctx.inside, %{"sort" => unquote(sort)})

        shown = listing(conn)
        assert shown["folder_details"]["Ordered/Inside"]["sort"] == unquote(sort)
        assert drawn(shown, "Ordered/Inside", top) == tree(board, {:folder, ctx.inside.id})
        assert drawn(shown, "Ordered", top) == tree(board, :root)
      end
    end

    test "the sorts really differ", %{conn: conn, board: board, pages: [a, b, c]} do
      orders =
        for sort <- ~w(manual name modified created) do
          {:ok, _} = Wiki.set_tree_sort(board, nil, sort)
          conn |> listing() |> drawn("Ordered", sort) |> Enum.filter(&(elem(&1, 0) == "page"))
        end

      assert orders == [
               [{"page", b}, {"page", c}, {"page", a}],
               [{"page", a}, {"page", b}, {"page", c}],
               [{"page", b}, {"page", c}, {"page", a}],
               [{"page", a}, {"page", c}, {"page", b}]
             ]
    end

    test "folders stay as arranged unless the sort is by name",
         %{conn: conn, board: board} = ctx do
      {:ok, _} = Wiki.set_tree_sort(board, nil, "modified")
      zebra = listing(conn)["folder_details"]["Ordered/zebra"]["id"]

      assert [{"folder", ^zebra}, {"folder", id} | _] =
               drawn(listing(conn), "Ordered", "modified")

      assert id == ctx.inside.id
    end

    test "files come last, by name, whatever the sort",
         %{conn: conn, board: board, user: user} = ctx do
      file(board, user, "b.png", ctx.inside.id)
      file(board, user, "A.png", ctx.inside.id)
      {:ok, _} = Folders.update(ctx.inside, %{"sort" => "modified"})

      shown = drawn(listing(conn), "Ordered/Inside", "name")
      assert shown == tree(board, {:folder, ctx.inside.id})
      assert [{"file", _}, {"file", _}] = Enum.take(shown, -2)
    end
  end

  describe "what is also filed in a folder" do
    setup %{board: board, user: user} do
      first = page!(board, "Zulu", nil, 9, 1000, 1000)
      second = page!(board, "Alpha", nil, 1, 2000, 2000)
      shelf = folder!(board, "Shelf", 0)
      page!(board, "At home", shelf, 0, 1000, 1000)

      {:ok, _} = Placements.add(Repo.get!(Page, first), shelf, user)
      {:ok, _} = Placements.add(Repo.get!(Page, second), shelf, user)
      %{first: first, second: second, shelf: shelf}
    end

    test "comes in the placements' order, not the pages' own", %{conn: conn} = ctx do
      shown = listing(conn)

      assert shown["folder_details"]["Ordered/Shelf"]["also_pages"] == [ctx.first, ctx.second]

      assert entry(shown, "Ordered/Zulu.md")["position"] >
               entry(shown, "Ordered/Alpha.md")["position"]
    end

    test "a page's position there can differ from its position at home", %{conn: conn} = ctx do
      from(pl in Slipdock.Wiki.Placement, where: pl.page_id == ^ctx.first)
      |> Repo.update_all(set: [position: 5])

      shown = listing(conn)
      assert shown["folder_details"]["Ordered/Shelf"]["also_pages"] == [ctx.second, ctx.first]
      assert entry(shown, "Ordered/Zulu.md")["position"] == 9
    end

    test "comes after the pages at home, under every sort", %{conn: conn, board: board} = ctx do
      for sort <- ~w(manual name modified created) do
        {:ok, _} = Folders.update(ctx.shelf, %{"sort" => sort})

        assert drawn(listing(conn), "Ordered/Shelf", "name") ==
                 tree(board, {:folder, ctx.shelf.id})
      end
    end

    test "leaves out a draft the reader can't open", %{conn: conn, user: user} = ctx do
      other = board_fixture(%{"name" => "Theirs", "code" => "or88"}, owner: user)
      {:ok, lent} = Wiki.create_page(other, %{"title" => "Lent"})
      {:ok, draft} = Wiki.create_page(other, %{"title" => "Hidden", "status" => "draft"})

      {:ok, _} = Placements.add(lent, ctx.shelf, user)
      {:ok, _} = Placements.add(draft, ctx.shelf, user)

      assert draft.id in listing(conn)["folder_details"]["Ordered/Shelf"]["also_pages"]

      also = (conn |> with_token(user, scope: "read") |> listing())["folder_details"]
      also = also["Ordered/Shelf"]["also_pages"]

      assert lent.id in also
      refute draft.id in also
    end

    test "leaves out a folder on a board the token can't open", ctx do
      other = board_fixture(%{"name" => "Beyond", "code" => "or89"}, owner: ctx.user)
      beyond = folder!(other, "Beyond", 0)
      {:ok, _} = FolderPlacements.add(beyond, ctx.shelf, ctx.user)

      assert [_] = listing(ctx.conn)["folder_details"]["Ordered/Shelf"]["also_folders"]

      body = ctx.conn |> with_token(ctx.user, scope_boards: [ctx.board.id]) |> listing()
      assert body["folder_details"]["Ordered/Shelf"]["also_folders"] == []
    end

    test "says a folder filed there, in order", %{conn: conn, board: board, user: user} = ctx do
      later = folder!(board, "Aardvark", 5)
      earlier = folder!(board, "Yak", 6)
      {:ok, _} = FolderPlacements.add(earlier, ctx.shelf, user)
      {:ok, _} = FolderPlacements.add(later, ctx.shelf, user)

      shown = listing(conn)
      assert shown["folder_details"]["Ordered/Shelf"]["also_folders"] == [earlier.id, later.id]
      assert drawn(shown, "Ordered/Shelf", "name") == tree(board, {:folder, ctx.shelf.id})
    end
  end

  describe "setting the top's sort" do
    test "with a token, and the vault's board says it", %{
      conn: conn,
      user: user,
      board: board
    } do
      answer =
        conn
        |> with_token(user)
        |> patch("/api/boards/#{board.code}/tree", %{"sort" => "modified"})
        |> json_response(200)

      assert answer["board"]["wiki_sort"] == "modified"
      assert Slipdock.Boards.get_board!(board.id).wiki_sort == "modified"
      assert [%{"wiki_sort" => "modified"}] = boards_json(conn)
    end

    test "refuses a sort that isn't one, or none, or board", %{conn: conn, board: board} do
      for body <- [%{"sort" => "random"}, %{}, %{"sort" => "board"}] do
        assert %{"error" => error} =
                 conn |> patch("/api/boards/#{board.code}/tree", body) |> json_response(422)

        assert error =~ "sort by"
      end

      assert Slipdock.Boards.get_board!(board.id).wiki_sort == "name"
    end

    test "takes a writer, as the web tree does, not only the owner", ctx do
      %{conn: conn, board: board, user: user} = ctx
      writer = user_fixture("order-writer@example.com")
      {:ok, _} = Access.grant(board, writer, "write", user)

      assert conn
             |> with_token(writer)
             |> patch("/api/boards/#{board.id}/tree", %{"sort" => "created"})
             |> json_response(200)
    end

    test "refuses a reader and a read-only token", %{conn: conn, user: user, board: board} do
      reader = user_fixture("order-reader@example.com")
      {:ok, _} = Access.grant(board, reader, "read", user)

      status =
        conn
        |> with_token(reader)
        |> patch("/api/boards/#{board.id}/tree", %{"sort" => "created"})

      assert status.status == 403

      read_only =
        conn
        |> with_token(user, scope: "read")
        |> patch("/api/boards/#{board.id}/tree", %{"sort" => "created"})

      assert read_only.status == 403
      assert Slipdock.Boards.get_board!(board.id).wiki_sort == "name"
    end
  end
end
