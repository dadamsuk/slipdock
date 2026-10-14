defmodule Slipdock.Wiki.IconsTest do
  @moduledoc """
  A wiki folder's and page's icon and colour (#792): what may be chosen, how a
  blank one clears it, a path's dress landing on the folder it names, the
  board's switch for the tree, and the two surviving an export and import.
  """
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Palette, Portable, Wiki}
  alias Slipdock.Wiki.{Folder, Icons, Tree}

  setup do
    user = user_fixture()
    board = board_fixture(%{"name" => "Dress", "code" => "dress792"}, owner: user)
    %{user: user, board: board}
  end

  describe "the set" do
    test "every icon draws as its Heroicon, and a name outside the set draws nothing" do
      assert "star" in Icons.names()
      assert Icons.class("star") == "hero-star"
      assert Icons.class("not-an-icon") == nil
      assert Icons.class(nil) == nil
      assert Enum.all?(Icons.names(), &(Icons.class(&1) == "hero-" <> &1))
    end

    test "a folder or page with no icon of its own draws the plain one of its kind" do
      assert Icons.class(nil, :folder) == "hero-folder"
      assert Icons.class(nil, :page) == "hero-document-text"
      assert Icons.class("bolt", :page) == "hero-bolt"
      assert Icons.class("nonsense", :folder) == "hero-folder"
    end

    test "a palette colour tints; none, blank or unknown does not" do
      assert Icons.tint("rose") == Palette.text("rose")
      assert Icons.tint("rose") =~ "text-rose-"
      assert Icons.tint(nil) == nil
      assert Icons.tint("") == nil
      assert Icons.tint("chartreuse") == nil
    end
  end

  describe "a folder" do
    test "is made wearing an icon and a colour, and they clear with blanks", %{board: board} do
      {:ok, folder} =
        Wiki.create_folder(board, %{"name" => "Ideas", "icon" => "light-bulb", "color" => "amber"})

      assert {folder.icon, folder.color} == {"light-bulb", "amber"}

      {:ok, cleared} = Wiki.update_folder(folder, %{"icon" => "", "color" => ""})
      assert {cleared.icon, cleared.color} == {nil, nil}
    end

    test "refuses an icon or colour outside the set", %{board: board} do
      assert {:error, changeset} = Wiki.create_folder(board, %{"name" => "X", "icon" => "dragon"})
      assert %{icon: ["is not one of the wiki's icons"]} = errors_on(changeset)

      assert {:error, changeset} = Wiki.create_folder(board, %{"name" => "Y", "color" => "plaid"})
      assert %{color: [_]} = errors_on(changeset)
    end

    test "made as a path, the dress goes on the folder it names, not the way there", %{
      board: board
    } do
      {:ok, leaf} =
        Wiki.create_folder(board, %{
          "name" => "Design/Decisions",
          "icon" => "flag",
          "color" => "sky"
        })

      assert {leaf.name, leaf.icon, leaf.color} == {"Decisions", "flag", "sky"}

      {:ok, top} = Wiki.find_folder(board, "Design")
      assert {top.icon, top.color} == {nil, nil}
    end

    test "a path made without dress is left as it was", %{board: board} do
      {:ok, leaf} = Wiki.create_folder(board, %{"name" => "A/B"})
      assert {leaf.icon, leaf.color} == {nil, nil}
    end
  end

  describe "a page" do
    test "wears an icon tinted by the colour it already carries", %{board: board, user: user} do
      page = page_fixture(board, %{"icon" => "trophy", "color" => "emerald"}, user: user)
      assert {page.icon, page.color} == {"trophy", "emerald"}

      {:ok, page} = Wiki.update_page(page, %{"icon" => ""}, user: user)
      assert page.icon == nil
      assert page.color == "emerald"
    end

    test "refuses an icon outside the set", %{board: board, user: user} do
      assert {:error, changeset} =
               Wiki.create_page(board, %{"title" => "Nope", "icon" => "dragon"}, user: user)

      assert %{icon: [_]} = errors_on(changeset)
    end
  end

  test "the tree's rows carry each folder's and page's icon and colour", %{
    board: board,
    user: user
  } do
    {:ok, folder} =
      Wiki.create_folder(board, %{"name" => "Ops", "icon" => "key", "color" => "red"})

    page_fixture(board, %{"title" => "Runbook", "icon" => "fire", "folder_id" => folder.id},
      user: user
    )

    page_fixture(board, %{"title" => "Plain"}, user: user)

    {:ok, top} = Tree.children(board, :root, [])
    assert %{icon: "key", color: "red"} = Enum.find(top, &(&1.title == "Ops"))
    assert %{icon: nil, color: nil} = Enum.find(top, &(&1.title == "Plain"))

    {:ok, inside} = Tree.children(board, {:folder, folder.id}, [])
    assert [%{title: "Runbook", icon: "fire", color: nil}] = inside
  end

  test "the board's tree shows icons and colours until a writer turns them off", %{board: board} do
    assert board.wiki_tree_icons
    assert Wiki.tree_icons?(board.id)

    assert {:ok, %{wiki_tree_icons: false}} = Wiki.set_tree_icons(board, false)
    refute Wiki.tree_icons?(board.id)

    assert {:ok, _} = Wiki.set_tree_icons(board, true)
    assert Wiki.tree_icons?(board.id)
    assert Wiki.tree_icons?(-1) == nil
  end

  test "an export carries them and an import brings them back", %{board: board, user: user} do
    {:ok, folder} =
      Wiki.create_folder(board, %{"name" => "Ideas", "icon" => "sparkles", "color" => "violet"})

    page_fixture(
      board,
      %{
        "title" => "Big one",
        "icon" => "rocket-launch",
        "color" => "rose",
        "folder_id" => folder.id
      },
      user: user
    )

    document = user |> Portable.export() |> Jason.encode!()

    # Under its own code, so it cannot meet this board's.
    document = String.replace(document, ~s("dress792"), ~s("dress792b"))
    {:ok, %{boards: [%{id: id}]}} = Portable.import(user_fixture(), document)

    [copy] = Repo.all(from(f in Folder, where: f.board_id == ^id))
    assert {copy.icon, copy.color} == {"sparkles", "violet"}

    [page] = Repo.all(from(p in Slipdock.Wiki.Page, where: p.board_id == ^id))
    assert {page.icon, page.color} == {"rocket-launch", "rose"}
  end

  test "an icon or colour this server does not know is dropped, not the folder or page" do
    tree = %{
      root: %{ref: "r", name: "Imported", code: "dress792c", lists: [%{ref: "l1", name: "To Do"}]},
      folders: [
        %{ref: "f1", board: "r", name: "Odd", slug: "odd", icon: "dragon", color: "plaid"}
      ],
      pages: [%{ref: "p1", board: "r", title: "Odd page", code: "", body: "", icon: "dragon"}]
    }

    document = Jason.encode!(%{slipdock_portable: 1, boards: [tree]})
    {:ok, %{boards: [%{id: id}]}} = Portable.import(user_fixture(), document)

    assert [%Folder{name: "Odd", icon: nil, color: nil}] =
             Repo.all(from(f in Folder, where: f.board_id == ^id))

    assert [%{title: "Odd page", icon: nil}] =
             Repo.all(from(p in Slipdock.Wiki.Page, where: p.board_id == ^id))
  end
end
