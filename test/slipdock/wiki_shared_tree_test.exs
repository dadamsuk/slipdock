defmodule Slipdock.WikiSharedTreeTest do
  @moduledoc "The Shared with me tree (#817): grouping, nesting and the empty state."
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Access, Wiki}
  alias Slipdock.Wiki.{Files, Placements, SharedTree}

  setup do
    alice = user_fixture("alice@example.com")
    bob = user_fixture("bob@example.com")
    me = user_fixture("me@example.com")
    %{alice: alice, bob: bob, me: me}
  end

  test "nothing shared is an empty tree", %{me: me} do
    assert SharedTree.for_user(me) == []
    refute SharedTree.any?(me)
    assert SharedTree.for_user(nil) == []
  end

  test "shares are grouped by whose they are, owners and items in order", c do
    a_board = board_fixture(%{"name" => "Alice's"}, owner: c.alice)
    b_board = board_fixture(%{"name" => "Bob's"}, owner: c.bob)
    {:ok, zeta} = Wiki.create_folder(a_board, %{"name" => "Zeta"})
    {:ok, alpha} = Wiki.create_folder(a_board, %{"name" => "Alpha"})
    lone = page_fixture(a_board, %{"title" => "Aardvark"}, user: c.alice)
    bobs = page_fixture(b_board, %{"title" => "Bob's note"}, user: c.bob)

    for {thing, owner} <- [{zeta, c.alice}, {alpha, c.alice}, {lone, c.alice}, {bobs, c.bob}],
        do: {:ok, _} = Access.grant(thing, c.me, "read", owner)

    assert [%{owner: first, items: a_items}, %{owner: second, items: b_items}] =
             SharedTree.for_user(c.me)

    assert first.id == c.alice.id and second.id == c.bob.id
    # Folders first, by name; then pages.
    assert Enum.map(a_items, &label/1) == ["Alpha", "Zeta", "Aardvark"]
    assert Enum.map(b_items, &label/1) == ["Bob's note"]
    assert hd(b_items).level == :read
  end

  test "a comment share shows at comment level, and a write share beside it wins", c do
    board = board_fixture(%{"name" => "Alice's"}, owner: c.alice)
    {:ok, folder} = Wiki.create_folder(board, %{"name" => "Notes"})
    page = page_fixture(board, %{"title" => "Plan"}, user: c.alice)
    {:ok, _} = Access.grant(folder, c.me, "comment", c.alice)
    {:ok, _} = Access.grant(page, c.me, "comment", c.alice)

    assert [%{items: [%{kind: :folder, level: :comment}, %{kind: :page, level: :comment}]}] =
             SharedTree.for_user(c.me)

    {:ok, group} = Slipdock.Accounts.create_group(c.alice, %{"name" => "Crew"})
    {:ok, _} = Slipdock.Accounts.add_group_member(group, c.me.email)
    {:ok, _} = Access.grant(folder, group, "write", c.alice)

    assert [%{items: [%{kind: :folder, level: :write}, %{kind: :page, level: :comment}]}] =
             SharedTree.for_user(c.me)

    assert Access.folder_grant_level(c.me, folder.id) == :write
  end

  test "a shared folder opens to its whole subtree: folders, pages and files", c do
    board = board_fixture(%{"name" => "Handbook"}, owner: c.alice)
    {:ok, top} = Wiki.create_folder(board, %{"name" => "Top"})
    {:ok, mid} = Wiki.create_folder(board, %{"name" => "Mid", "parent_id" => top.id})
    {:ok, deep} = Wiki.create_folder(board, %{"name" => "Deep", "parent_id" => mid.id})
    page_fixture(board, %{"title" => "At the top", "folder_id" => top.id}, user: c.alice)
    page_fixture(board, %{"title" => "Way down", "folder_id" => deep.id}, user: c.alice)

    page_fixture(board, %{"title" => "A draft", "folder_id" => top.id, "status" => "draft"},
      user: c.alice
    )

    path = Path.join(System.tmp_dir!(), "tree-#{System.unique_integer([:positive])}.png")
    File.write!(path, "png")
    on_exit(fn -> File.rm(path) end)
    {:ok, _} = Files.create(board, %{name: "chart.png", folder_id: mid.id}, path)

    {:ok, _} = Access.grant(top, c.me, "read", c.alice)

    assert [%{items: [node]}] = SharedTree.for_user(c.me)
    assert node.folder.id == top.id and node.level == :read
    # A reader sees no drafts.
    assert Enum.map(node.pages, & &1.title) == ["At the top"]

    assert [%{folder: %{name: "Mid"}, files: [%{name: "chart.png"}], folders: [deep_node]}] =
             node.folders

    assert deep_node.folder.id == deep.id
    assert Enum.map(deep_node.pages, & &1.title) == ["Way down"]
  end

  test "a writer of the share sees its drafts, and a folder shared inside another shows once",
       c do
    board = board_fixture(%{"name" => "Handbook"}, owner: c.alice)
    {:ok, top} = Wiki.create_folder(board, %{"name" => "Top"})
    {:ok, inner} = Wiki.create_folder(board, %{"name" => "Inner", "parent_id" => top.id})

    page_fixture(board, %{"title" => "Draft", "folder_id" => inner.id, "status" => "draft"},
      user: c.alice
    )

    {:ok, _} = Access.grant(top, c.me, "read", c.alice)
    {:ok, _} = Access.grant(inner, c.me, "write", c.alice)

    assert [%{items: [node]}] = SharedTree.for_user(c.me)
    assert node.folder.id == top.id
    assert [%{level: :write, pages: [%{title: "Draft"}]}] = node.folders
  end

  test "what is only also filed in a shared folder is not in it", c do
    board = board_fixture(%{"name" => "Handbook"}, owner: c.alice)
    {:ok, shared} = Wiki.create_folder(board, %{"name" => "Shared"})
    {:ok, private} = Wiki.create_folder(board, %{"name" => "Private"})
    secret = page_fixture(board, %{"title" => "Secret", "folder_id" => private.id}, user: c.alice)
    {:ok, _} = Placements.add(secret, shared, c.alice)
    {:ok, _} = Access.grant(shared, c.me, "read", c.alice)

    assert [%{items: [%{pages: []}]}] = SharedTree.for_user(c.me)
  end

  test "a page shared on its own inside a shared folder shows once, in the folder", c do
    board = board_fixture(%{"name" => "Handbook"}, owner: c.alice)
    {:ok, shared} = Wiki.create_folder(board, %{"name" => "Shared"})
    page = page_fixture(board, %{"title" => "Both", "folder_id" => shared.id}, user: c.alice)
    {:ok, _} = Access.grant(shared, c.me, "read", c.alice)
    {:ok, _} = Access.grant(page, c.me, "write", c.alice)

    assert [%{items: [%{kind: :folder, pages: [%{title: "Both"}]}]}] = SharedTree.for_user(c.me)
  end

  test "the reader's own boards are left out", c do
    board = board_fixture(%{"name" => "Mine"}, owner: c.me)
    {:ok, folder} = Wiki.create_folder(board, %{"name" => "Mine too"})
    {:ok, _} = Access.grant(folder, c.me, "write", c.me)

    assert SharedTree.for_user(c.me) == []
  end

  defp label(%{kind: :folder, folder: f}), do: f.name
  defp label(%{kind: :page, page: p}), do: p.title
end
