defmodule Slipdock.WikiFoldersTest do
  @moduledoc """
  Folders: filing pages on a board's wiki, to any depth.

  The point of the module is that filing never destroys writing, so most of
  what is worth testing is what *survives* — a deleted folder's pages, a
  moved folder's subtree, a page's parent when it is filed somewhere else.
  """
  use Slipdock.DataCase, async: false

  import Slipdock.Fixtures

  alias Slipdock.Wiki
  alias Slipdock.Wiki.Folders

  setup do
    user = user_fixture()
    board = board_fixture(%{"name" => "Handbook", "code" => "handbook"}, owner: user)
    %{user: user, board: board}
  end

  defp page(board, user, title, opts \\ []) do
    {:ok, page} =
      Wiki.create_page(board, %{"title" => title, "body" => "…"}, user: user)

    case opts[:folder] do
      nil -> page
      folder -> elem(Folders.put_page(page, folder), 1)
    end
  end

  describe "making them" do
    test "a folder is named, slugged and found by either", %{board: board} do
      {:ok, folder} = Wiki.create_folder(board, %{"name" => "Design decisions"})

      assert folder.slug == "design-decisions"
      assert {:ok, ^folder} = Wiki.find_folder(board, "design-decisions")
      assert {:ok, ^folder} = Wiki.find_folder(board, "Design Decisions")
      assert {:ok, ^folder} = Wiki.find_folder(board, folder.id)
    end

    test "a name with slashes makes the whole path", %{board: board} do
      {:ok, leaf} = Wiki.create_folder(board, %{"name" => "Design/Decisions/2026"})

      assert Wiki.folder_path(leaf) == "Design/Decisions/2026"
      assert length(Wiki.folders(board)) == 3
      assert {:ok, ^leaf} = Wiki.find_folder(board, "Design/Decisions/2026")
    end

    test "making the same path twice does not make it twice", %{board: board} do
      {:ok, first} = Wiki.create_folder(board, %{"name" => "Design/Decisions"})
      {:ok, again} = Wiki.create_folder(board, %{"name" => "Design/Decisions"})

      assert first.id == again.id
      assert length(Wiki.folders(board)) == 2
    end

    test "two folders cannot share a slug on one board", %{board: board} do
      {:ok, _} = Wiki.create_folder(board, %{"name" => "Notes"})
      {:ok, other} = Wiki.create_folder(board, %{"name" => "Archive/Notes"})

      assert other.slug != "notes"
    end
  end

  describe "the tree" do
    test "folders nest and hold the pages filed in them", %{board: board, user: user} do
      {:ok, design} = Wiki.create_folder(board, %{"name" => "Design"})

      {:ok, decisions} =
        Wiki.create_folder(board, %{"name" => "Decisions", "parent_id" => design.id})

      _loose = page(board, user, "Stray")
      _filed = page(board, user, "Colour", folder: design)
      _deep = page(board, user, "Why SQLite", folder: decisions)

      pages = Wiki.list_pages(board)
      [node] = Wiki.folder_tree(board, pages)

      assert node.folder.id == design.id
      assert Enum.map(node.pages, & &1.page.title) == ["Colour"]
      assert [%{folder: %{id: id}, pages: [%{page: %{title: "Why SQLite"}}]}] = node.children
      assert id == decisions.id
      assert Enum.map(Wiki.unfiled(pages), & &1.page.title) == ["Stray"]
      assert Folders.page_count(node) == 2
    end
  end

  describe "moving and deleting" do
    test "a folder cannot be moved inside itself", %{board: board} do
      {:ok, outer} = Wiki.create_folder(board, %{"name" => "Outer"})
      {:ok, inner} = Wiki.create_folder(board, %{"name" => "Inner", "parent_id" => outer.id})

      assert {:error, :unprocessable_entity, _} =
               Wiki.update_folder(outer, %{"parent_id" => inner.id})

      assert {:error, :unprocessable_entity, _} =
               Wiki.update_folder(outer, %{"parent_id" => outer.id})
    end

    test "deleting a folder keeps its pages and lifts its subfolders", %{
      board: board,
      user: user
    } do
      {:ok, outer} = Wiki.create_folder(board, %{"name" => "Outer"})
      {:ok, inner} = Wiki.create_folder(board, %{"name" => "Inner", "parent_id" => outer.id})
      filed = page(board, user, "Kept", folder: outer)

      {:ok, _} = Wiki.delete_folder(outer)

      assert Wiki.get_page!(filed.id).folder_id == nil
      assert Wiki.get_folder(inner.id).parent_id == nil
    end

    test "purging a folder deletes everything filed anywhere inside it", %{
      board: board,
      user: user
    } do
      {:ok, outer} = Wiki.create_folder(board, %{"name" => "Outer"})
      {:ok, inner} = Wiki.create_folder(board, %{"name" => "Inner", "parent_id" => outer.id})
      top = page(board, user, "Top", folder: outer)
      deep = page(board, user, "Deep", folder: inner)
      elsewhere = page(board, user, "Elsewhere")

      assert %{folders: 1, pages: 2} = Wiki.folder_contents_count(outer)

      {:ok, _} = Wiki.delete_folder(outer, :purge)

      assert Wiki.get_page(top.id) == nil
      assert Wiki.get_page(deep.id) == nil
      assert Wiki.get_folder(inner.id) == nil
      assert Wiki.get_folder(outer.id) == nil
      # A page filed somewhere else is none of a purge's business.
      assert Wiki.get_page!(elsewhere.id)
    end

    test "a purge counts the archived pages it would take", %{board: board, user: user} do
      {:ok, folder} = Wiki.create_folder(board, %{"name" => "Specs"})
      filed = page(board, user, "Old", folder: folder)
      {:ok, _} = Wiki.archive_page(filed)

      assert %{folders: 0, pages: 1} = Wiki.folder_contents_count(folder)
    end

    test "a folder moved before another lands above it, packed in order", %{board: board} do
      {:ok, a} = Wiki.create_folder(board, %{"name" => "Alpha"})
      {:ok, b} = Wiki.create_folder(board, %{"name" => "Beta"})
      {:ok, c} = Wiki.create_folder(board, %{"name" => "Gamma"})

      {:ok, _} = Wiki.move_folder(c, nil, a.id)

      assert Enum.map(Wiki.folders(board), & &1.name) == ["Gamma", "Alpha", "Beta"]
      assert Enum.map(Wiki.folders(board), & &1.position) == [0, 1, 2]

      # And a position asked for by name packs the same way.
      {:ok, _} = Wiki.update_folder(b, %{"position" => 0})
      assert Enum.map(Wiki.folders(board), & &1.name) == ["Beta", "Gamma", "Alpha"]
      assert Enum.map(Wiki.folders(board), & &1.position) == [0, 1, 2]
    end

    test "the outline gives every folder its path and depth, in reading order", %{board: board} do
      {:ok, _} = Wiki.create_folder(board, %{"name" => "Design/Decisions"})
      {:ok, _} = Wiki.create_folder(board, %{"name" => "Runbooks"})

      outline = Wiki.folder_outline(board)

      assert Enum.map(outline, &{&1.path, &1.depth}) == [
               {"Design", 0},
               {"Design/Decisions", 1},
               {"Runbooks", 0}
             ]
    end

    test "filing a page leaves its place in the page tree alone", %{board: board, user: user} do
      {:ok, folder} = Wiki.create_folder(board, %{"name" => "Specs"})
      parent = page(board, user, "Spec")

      {:ok, child} =
        Wiki.create_page(board, %{"title" => "Rollback", "parent_id" => parent.id}, user: user)

      {:ok, child} = Wiki.file_page(child, folder)

      assert child.folder_id == folder.id
      assert child.parent_id == parent.id
    end
  end
end
