defmodule Slipdock.Vaults.SyncStubsTest do
  @moduledoc """
  Stubs (#819): what is shared with somebody and filed in their own vault
  syncs as links to the original, never as its content.
  """
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Access, Vaults, Wiki}
  alias Slipdock.Vaults.Sync
  alias Slipdock.Wiki.{FolderPlacements, Placements}

  @base "https://slipdock.example.com"

  setup do
    owner = user_fixture("owner@example.com")
    sharee = user_fixture("sharee@example.com")

    theirs = board_fixture(%{"name" => "Owner's"}, owner: owner)
    {:ok, shared} = Wiki.create_folder(theirs, %{"name" => "Shared"})
    {:ok, deep} = Wiki.create_folder(theirs, %{"name" => "Deep", "parent_id" => shared.id})

    plan =
      page_fixture(
        theirs,
        %{"title" => "Plan", "body" => "TOP SECRET WORDS", "folder_id" => shared.id},
        user: owner
      )

    inner =
      page_fixture(
        theirs,
        %{"title" => "Inner", "body" => "MORE SECRET WORDS", "folder_id" => deep.id},
        user: owner
      )

    path = Path.join(System.tmp_dir!(), "stub-#{System.unique_integer([:positive])}.png")
    File.write!(path, "SECRET PNG BYTES")
    on_exit(fn -> File.rm(path) end)
    {:ok, chart} = Wiki.Files.create(theirs, %{name: "chart.png", folder_id: deep.id}, path)

    mine = board_fixture(%{"name" => "Mine"}, owner: sharee)
    {:ok, inbox} = Wiki.create_folder(mine, %{"name" => "Inbox"})
    page_fixture(mine, %{"title" => "My note", "folder_id" => inbox.id}, user: sharee)
    {:ok, vault} = Vaults.create_vault(sharee, %{"name" => "Brain"})
    {:ok, _} = Vaults.add_mapping(vault, sharee, %{path: "/", board: mine})

    %{
      owner: owner,
      sharee: sharee,
      theirs: theirs,
      shared: shared,
      deep: deep,
      plan: plan,
      inner: inner,
      chart: chart,
      mine: mine,
      inbox: inbox,
      vault: vault
    }
  end

  defp listing(c, opts \\ [stubs: true, base_url: @base]),
    do: Sync.listing(c.vault, c.sharee, opts)

  defp stubs(listing), do: for(%{kind: "stub"} = e <- listing.entries, into: %{}, do: {e.path, e})

  test "a shared page filed in the vault is a stub: one line, a link, none of its words", c do
    {:ok, _} = Access.grant(c.plan, c.sharee, "read", c.owner)
    {:ok, _} = Placements.add(c.plan, c.inbox, c.sharee)

    assert %{"Inbox/Plan.md" => stub} = stubs(listing(c))
    assert stub.content == "[Plan](#{@base}/shared/pages/#{c.plan.id})\n"
    assert stub.hash == Sync.hash(stub.content)
    refute stub.content =~ "SECRET"
    # The sharee's own note syncs as ever, beside it.
    assert Enum.any?(listing(c).entries, &(&1.kind == "page" and &1.path == "Inbox/My note.md"))
  end

  test "a shared folder is a directory of stubs mirroring its subtree, files included", c do
    {:ok, _} = Access.grant(c.shared, c.sharee, "read", c.owner)
    {:ok, _} = FolderPlacements.add(c.shared, c.inbox, c.sharee)

    listed = listing(c)
    found = stubs(listed)

    assert Map.keys(found) |> Enum.sort() ==
             [
               "Inbox/Shared/Deep/Inner.md",
               "Inbox/Shared/Deep/chart.png.md",
               "Inbox/Shared/Plan.md"
             ]

    assert found["Inbox/Shared/Deep/chart.png.md"].content =~
             "[chart.png](#{@base}/files/#{c.chart.id}"

    assert "Inbox/Shared" in listed.folders
    assert "Inbox/Shared/Deep" in listed.folders

    # Not a word, nor a byte, of what was shared.
    for {_path, stub} <- found, do: refute(stub.content =~ "SECRET")
  end

  test "renamed inside the share, the stub follows", c do
    {:ok, _} = Access.grant(c.shared, c.sharee, "read", c.owner)
    {:ok, _} = FolderPlacements.add(c.shared, c.inbox, c.sharee)
    before = stubs(listing(c))["Inbox/Shared/Plan.md"]

    {:ok, _} = Wiki.update_page(c.plan, %{"title" => "Plan B"}, user: c.owner)
    {:ok, _} = Wiki.update_page(c.inner, %{"folder_id" => c.shared.id}, user: c.owner)

    found = stubs(listing(c))
    refute Map.has_key?(found, "Inbox/Shared/Plan.md")
    assert found["Inbox/Shared/Plan B.md"].id == before.id
    assert Map.has_key?(found, "Inbox/Shared/Inner.md")
    refute Map.has_key?(found, "Inbox/Shared/Deep/Inner.md")
  end

  test "revoking the share, or taking the placement out, takes the stubs away", c do
    {:ok, grant} = Access.grant(c.shared, c.sharee, "read", c.owner)
    {:ok, _} = FolderPlacements.add(c.shared, c.inbox, c.sharee)
    assert stubs(listing(c)) != %{}

    {:ok, _} = Access.revoke(grant)
    assert stubs(listing(c)) == %{}
    refute "Inbox/Shared" in listing(c).folders

    {:ok, _} = Access.grant(c.plan, c.sharee, "read", c.owner)
    {:ok, _} = Placements.add(c.plan, c.inbox, c.sharee)
    assert Map.has_key?(stubs(listing(c)), "Inbox/Plan.md")
    {:ok, _} = Placements.remove(c.plan, c.inbox, c.sharee)
    assert stubs(listing(c)) == %{}
  end

  test "a client that doesn't ask for stubs gets none", c do
    {:ok, _} = Access.grant(c.plan, c.sharee, "read", c.owner)
    {:ok, _} = Placements.add(c.plan, c.inbox, c.sharee)

    assert stubs(listing(c, [])) == %{}
  end

  test "a stub never takes the name of a real file there", c do
    page_fixture(c.mine, %{"title" => "Plan", "folder_id" => c.inbox.id}, user: c.sharee)
    {:ok, _} = Access.grant(c.plan, c.sharee, "read", c.owner)
    {:ok, _} = Placements.add(c.plan, c.inbox, c.sharee)

    assert Map.has_key?(stubs(listing(c)), "Inbox/Plan (shared).md")
  end

  test "the owner's own sync is unchanged", c do
    {:ok, owner_vault} = Vaults.create_vault(c.owner, %{"name" => "Owner's vault"})
    {:ok, _} = Vaults.add_mapping(owner_vault, c.owner, %{path: "/", board: c.theirs})
    {:ok, _} = Access.grant(c.plan, c.sharee, "read", c.owner)
    {:ok, _} = Placements.add(c.plan, c.inbox, c.sharee)

    listed = Sync.listing(owner_vault, c.owner, stubs: true, base_url: @base)
    refute Enum.any?(listed.entries, &(&1.kind == "stub"))
    assert Enum.any?(listed.entries, &(&1.kind == "page" and &1.path == "Shared/Plan.md"))
  end
end
