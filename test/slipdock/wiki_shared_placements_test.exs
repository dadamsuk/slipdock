defmodule Slipdock.WikiSharedPlacementsTest do
  @moduledoc "Filing a page or folder shared with you into your own tree (#818)."
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Access, Wiki}
  alias Slipdock.Wiki.{FolderPlacements, Placements, Tree}

  setup do
    owner = user_fixture("owner@example.com")
    sharee = user_fixture("sharee@example.com")
    theirs = board_fixture(%{"name" => "Owner's"}, owner: owner)
    mine = board_fixture(%{"name" => "Sharee's"}, owner: sharee)
    {:ok, shared} = Wiki.create_folder(theirs, %{"name" => "Shared"})
    page = page_fixture(theirs, %{"title" => "Plan", "folder_id" => shared.id}, user: owner)
    {:ok, inbox} = Wiki.create_folder(mine, %{"name" => "Inbox"})

    %{
      owner: owner,
      sharee: sharee,
      theirs: theirs,
      mine: mine,
      shared: shared,
      page: page,
      inbox: inbox
    }
  end

  defp placed_titles(board, folder, reader) do
    {:ok, rows} = Tree.children(board, {:folder, folder.id}, as: reader)
    for %{also: true} = row <- rows, do: row.title
  end

  test "a page shared to read can be filed in a folder of your own", c do
    {:ok, _} = Access.grant(c.page, c.sharee, "read", c.owner)

    assert {:ok, _} = Placements.add(c.page, c.inbox, c.sharee)
    assert placed_titles(c.mine, c.inbox, c.sharee) == ["Plan"]
  end

  test "a folder shared with you can be filed in a folder of your own", c do
    {:ok, _} = Access.grant(c.shared, c.sharee, "read", c.owner)

    assert {:ok, _} = FolderPlacements.add(c.shared, c.inbox, c.sharee)
    assert [%{id: id}] = FolderPlacements.placed_in(c.inbox, c.sharee)
    assert id == c.shared.id
    # Its contents come with it, through the share.
    assert Enum.map(FolderPlacements.pages_in(c.inbox, c.sharee), & &1.title) == ["Plan"]
  end

  test "refused with no access to the item", c do
    assert {:error, _, _} = Placements.add(c.page, c.inbox, c.sharee)
    assert {:error, _, _} = FolderPlacements.add(c.shared, c.inbox, c.sharee)
  end

  test "refused into a folder you can only read", c do
    {:ok, _} = Access.grant(c.page, c.sharee, "read", c.owner)
    third = user_fixture("third@example.com")
    reads = board_fixture(%{"name" => "Read only"}, owner: third)
    {:ok, folder} = Wiki.create_folder(reads, %{"name" => "Theirs"})
    {:ok, _} = Access.grant(reads, c.sharee, "read", third)

    assert {:error, :forbidden, _} = Placements.add(c.page, folder, c.sharee)
  end

  test "the placement shows only to people who can read the item", c do
    {:ok, _} = Access.grant(c.page, c.sharee, "read", c.owner)
    {:ok, _} = Placements.add(c.page, c.inbox, c.sharee)

    colleague = user_fixture("colleague@example.com")
    {:ok, _} = Access.grant(c.mine, colleague, "write", c.sharee)

    assert placed_titles(c.mine, c.inbox, c.sharee) == ["Plan"]
    assert placed_titles(c.mine, c.inbox, colleague) == []
    assert placed_titles(c.mine, c.inbox, nil) == []
  end

  test "revoking the share removes the placement, and sharing again doesn't bring it back", c do
    {:ok, grant} = Access.grant(c.page, c.sharee, "read", c.owner)
    {:ok, _} = Placements.add(c.page, c.inbox, c.sharee)

    {:ok, _} = Access.revoke(grant)
    assert Placements.folders(c.page) == []
    assert placed_titles(c.mine, c.inbox, c.sharee) == []

    {:ok, _} = Access.grant(c.page, c.sharee, "read", c.owner)
    assert placed_titles(c.mine, c.inbox, c.sharee) == []
  end

  test "revoking a folder share removes its placements and those of the pages in it", c do
    {:ok, grant} = Access.grant(c.shared, c.sharee, "read", c.owner)
    {:ok, _} = FolderPlacements.add(c.shared, c.inbox, c.sharee)
    {:ok, _} = Placements.add(c.page, c.inbox, c.sharee)

    {:ok, _} = Access.revoke(grant)
    assert FolderPlacements.folders(c.shared) == []
    assert Placements.folders(c.page) == []
  end

  test "revoking leaves the owner's own placements alone", c do
    {:ok, other} = Wiki.create_folder(c.theirs, %{"name" => "Other"})
    {:ok, _} = Placements.add(c.page, other, c.owner)
    {:ok, grant} = Access.grant(c.page, c.sharee, "read", c.owner)
    {:ok, _} = Access.revoke(grant)

    assert [%{id: id}] = Placements.folders(c.page)
    assert id == other.id
  end

  test "taking the placement out leaves the share and the page as they were", c do
    {:ok, _} = Access.grant(c.page, c.sharee, "read", c.owner)
    {:ok, _} = Placements.add(c.page, c.inbox, c.sharee)

    assert {:ok, []} = Placements.remove(c.page, c.inbox, c.sharee)
    assert Access.page_permission(c.sharee, c.page) == :read
    assert Wiki.get_page!(c.page.id).folder_id == c.shared.id
  end
end
