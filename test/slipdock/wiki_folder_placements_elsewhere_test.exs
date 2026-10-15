defmodule Slipdock.WikiFolderPlacementsElsewhereTest do
  @moduledoc """
  A folder also filed in another, everywhere outside the tree (#808, #811):
  a synced vault writes it once, at home; Organise… and Flatten leave the
  placements standing and copy nothing; and a folder's listing has the
  pages under the folders placed in it, marked `also`.
  """
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Vaults, Wiki}
  alias Slipdock.Vaults.Sync
  alias Slipdock.Wiki.{AutoOrganise, Changes, FolderPlacements}

  setup do
    user = user_fixture()
    kb = board_fixture(%{"name" => "Keystone", "code" => "fpel"}, owner: user)
    jobs = board_fixture(%{"name" => "Journal", "code" => "fpeljobs"}, owner: user)
    {:ok, vault} = Vaults.create_vault(user, %{"name" => "Brain"})
    {:ok, _} = Vaults.add_mapping(vault, user, %{path: "/", board: kb})
    {:ok, _} = Vaults.add_mapping(vault, user, %{path: "/Journal", board: jobs})

    {:ok, specs} = Wiki.create_folder(kb, %{"name" => "Specs"})
    {:ok, old} = Wiki.create_folder(kb, %{"name" => "Old", "parent_id" => specs.id})
    {:ok, ideas} = Wiki.create_folder(kb, %{"name" => "Ideas"})
    {:ok, call} = Wiki.create_page(kb, %{"title" => "Call", "folder_id" => specs.id}, user: user)

    {:ok, ancient} =
      Wiki.create_page(kb, %{"title" => "Ancient", "folder_id" => old.id}, user: user)

    %{
      user: user,
      kb: kb,
      jobs: jobs,
      vault: vault,
      specs: specs,
      old: old,
      ideas: ideas,
      call: call,
      ancient: ancient
    }
  end

  defp titles(pages), do: pages |> Enum.map(&{&1.title, &1.also}) |> Enum.sort()

  describe "vault sync" do
    test "writes a placed folder once, at its home: no extra files, no extra directories", ctx do
      before = Sync.listing(ctx.vault, ctx.user)
      start = Changes.since(ctx.vault, nil, ctx.user).cursor

      {:ok, _} = FolderPlacements.add(ctx.specs, ctx.ideas, ctx.user)
      {:ok, notes} = Wiki.create_folder(ctx.jobs, %{"name" => "Notes"})
      {:ok, _} = FolderPlacements.add(ctx.old, notes, ctx.user)

      listing = Sync.listing(ctx.vault, ctx.user)
      assert Enum.map(listing.entries, & &1.path) == Enum.map(before.entries, & &1.path)
      assert "Specs/Call.md" in Enum.map(listing.entries, & &1.path)
      refute Enum.any?(listing.entries, &String.starts_with?(&1.path, "Ideas/"))
      assert listing.folders == Enum.sort(before.folders ++ ["Journal/Notes"])

      # The feed names the placed folders at their home paths, once each.
      changes = Changes.since(ctx.vault, start, ctx.user).changes
      folder_paths = for %{subject: "folder", path: path} <- changes, do: path
      # (A folder's path in the feed is its path on its own board.)
      assert Enum.sort(folder_paths) == ["Notes", "Specs", "Specs/Old"]
      refute Enum.any?(changes, &(&1[:path] && String.starts_with?(&1.path, "Ideas/")))
    end
  end

  describe "Organise… and Flatten" do
    test "flattening a folder moves its own subfolders' pages, not a placed folder's", ctx do
      {:ok, outside} = Wiki.create_folder(ctx.kb, %{"name" => "Outside"})

      {:ok, kept} =
        Wiki.create_page(ctx.kb, %{"title" => "Kept", "folder_id" => outside.id}, user: ctx.user)

      {:ok, _} = FolderPlacements.add(outside, ctx.specs, ctx.user)
      {:ok, _} = FolderPlacements.add(ctx.old, ctx.ideas, ctx.user)

      {:ok, plan} = AutoOrganise.plan(ctx.specs, "flatten", user: ctx.user)
      assert Enum.map(plan, & &1.title) == ["Ancient"]
      {:ok, _} = AutoOrganise.apply_plan(ctx.kb, plan)

      assert Wiki.get_page!(ctx.ancient.id).folder_id == ctx.specs.id
      assert Wiki.get_page!(kept.id).folder_id == outside.id
      # Both placements still stand, between folders that still exist.
      assert [%{id: id}] = FolderPlacements.folders(Wiki.get_folder(outside.id))
      assert id == ctx.specs.id
      assert [_] = FolderPlacements.folders(Wiki.get_folder(ctx.old.id))
      assert length(Wiki.list_pages(ctx.kb)) == 3
    end

    test "organising by date files a folder's own pages, and leaves a placed one's", ctx do
      {:ok, _} = FolderPlacements.add(ctx.specs, ctx.ideas, ctx.user)
      {:ok, plan} = AutoOrganise.plan(ctx.ideas, "date", user: ctx.user)
      assert plan == []

      {:ok, plan} = AutoOrganise.plan(ctx.specs, "date", user: ctx.user)
      {:ok, _} = AutoOrganise.apply_plan(ctx.kb, plan)
      refute Wiki.get_page!(ctx.call.id).folder_id == ctx.specs.id
      assert [_] = FolderPlacements.folders(Wiki.get_folder(ctx.specs.id))
    end
  end

  describe "listing a folder" do
    test "has the pages anywhere under a folder placed in it, marked also", ctx do
      {:ok, _} = FolderPlacements.add(ctx.specs, ctx.ideas, ctx.user)

      assert titles(Wiki.list_pages(ctx.kb, folder: ctx.ideas, as: ctx.user)) == [
               {"Ancient", true},
               {"Call", true}
             ]

      # At home it is listed as it always was.
      assert titles(Wiki.list_pages(ctx.kb, folder: ctx.specs, as: ctx.user)) == [
               {"Call", false}
             ]

      # The listing's own filters reach them too.
      assert titles(Wiki.list_pages(ctx.kb, folder: ctx.ideas, as: ctx.user, q: "anc")) == [
               {"Ancient", true}
             ]
    end

    test "only what the reader may open: another board's placed folder needs its board", ctx do
      {:ok, desk} = Wiki.create_folder(ctx.jobs, %{"name" => "Desk"})

      {:ok, _} =
        Wiki.create_page(ctx.jobs, %{"title" => "Memo", "folder_id" => desk.id}, user: ctx.user)

      {:ok, _} = FolderPlacements.add(desk, ctx.ideas, ctx.user)

      assert titles(Wiki.list_pages(ctx.kb, folder: ctx.ideas, as: ctx.user)) == [{"Memo", true}]
      # Nobody named: only the folder's own board.
      assert Wiki.list_pages(ctx.kb, folder: ctx.ideas) == []

      reader = user_fixture("reader@example.com")
      share_fixture(ctx.kb, reader, "read")
      assert Wiki.list_pages(ctx.kb, folder: ctx.ideas, as: reader) == []
    end
  end
end
