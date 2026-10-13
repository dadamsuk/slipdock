defmodule Slipdock.Vaults.SplitTest do
  @moduledoc """
  Giving a vault folder its own board (#747): the folder's contents move to
  the board and its vault path is mapped onto it, in one step. The test
  that matters is a synced folder's: the moved notes keep their paths and
  bytes, so nothing about them changes; only the board's own pages arrive.
  """
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Repo, Vaults, Wiki}
  alias Slipdock.Boards.Board
  alias Slipdock.Vaults.{Mapping, Split, Sync}
  alias Slipdock.Wiki.{Folder, Page}

  setup do
    user = user_fixture()
    kb = board_fixture(%{"name" => "KnowledgeBase", "code" => "kbs"}, owner: user)
    hunt = board_fixture(%{"name" => "Job Hunt", "code" => "hunts"}, owner: user)
    {:ok, jobs} = Wiki.create_folder(kb, %{"name" => "Jobs"})
    {:ok, acme} = Wiki.create_folder(kb, %{"name" => "Acme", "parent_id" => jobs.id})

    {:ok, plan} =
      Wiki.create_page(kb, %{"title" => "Plan", "body" => "the plan", "folder_id" => jobs.id},
        user: user
      )

    {:ok, call} =
      Wiki.create_page(kb, %{"title" => "Call", "body" => "went well", "folder_id" => acme.id},
        user: user
      )

    {:ok, other} = Wiki.create_page(kb, %{"title" => "Recipes"}, user: user)
    {:ok, vault} = Vaults.create_vault(user, %{"name" => "GMinds"})
    {:ok, _} = Vaults.add_mapping(vault, user, %{path: "/", board: kb})

    %{
      user: user,
      kb: kb,
      hunt: hunt,
      jobs: jobs,
      acme: acme,
      plan: plan,
      call: call,
      other: other,
      vault: vault
    }
  end

  defp files(vault, user) do
    vault
    |> Sync.listing(user)
    |> Map.fetch!(:entries)
    |> Map.new(&{&1.path, &1.hash})
  end

  test "a synced folder sees no change to the moved notes; the board's own pages arrive", ctx do
    %{user: user, kb: kb, hunt: hunt, jobs: jobs, vault: vault} = ctx
    {:ok, _} = Wiki.create_page(hunt, %{"title" => "Already here", "body" => "old"}, user: user)
    before = files(vault, user)
    assert Map.has_key?(before, "Jobs/Plan.md")
    assert Map.has_key?(before, "Jobs/Acme/Call.md")

    assert {:ok, result} = Split.run(vault, user, "/Jobs", hunt)

    after_ = files(vault, user)
    # Every file that was there is there still, byte for byte.
    assert Map.take(after_, Map.keys(before)) == before
    # And the one new file is Job Hunt's own page, now under /Jobs.
    assert Map.keys(after_) -- Map.keys(before) == ["Jobs/Already here.md"]

    assert result.unchanged == 3
    assert result.renamed == []
    assert result.joining == %{count: 1, sample: ["Jobs/Already here.md"]}

    # The notes are Job Hunt's now, at its top; the folder is gone from
    # KnowledgeBase; /Jobs is mapped onto Job Hunt.
    assert %{board_id: hid, folder_id: nil} = Repo.get!(Page, ctx.plan.id)
    assert hid == hunt.id
    assert Repo.get!(Folder, ctx.acme.id).board_id == hunt.id
    refute Repo.get(Folder, jobs.id)
    assert Repo.get!(Page, ctx.other.id).board_id == kb.id

    assert {:ok, %Mapping{board_id: ^hid}, "Plan.md"} = Vaults.locate(vault, "/Jobs/Plan.md")
    assert Vaults.overlaps(vault) == []
  end

  test "the preview says the same, and changes nothing", ctx do
    %{user: user, kb: kb, hunt: hunt, vault: vault} = ctx
    {:ok, _} = Wiki.create_page(hunt, %{"title" => "Plan"}, user: user)

    assert {:ok, preview} = Split.preview(vault, user, "/Jobs", hunt)

    assert preview.path == "/Jobs"
    assert preview.from == "KnowledgeBase"
    assert preview.into == "Job Hunt"
    assert preview.move.pages == 2
    assert preview.move.title_clashes == ["Plan"]
    # Two notes called Plan in one place: the one that arrives later is told
    # apart by its code, which a synced folder sees as a rename.
    assert preview.joining.count == 1
    assert preview.unchanged + length(preview.renamed) == 3

    assert Repo.get!(Page, ctx.plan.id).board_id == kb.id
    assert [%{path: ""}] = Repo.preload(vault, :mappings, force: true).mappings
  end

  test "a new board can be made for it", ctx do
    %{user: user, vault: vault} = ctx

    assert {:ok, preview} = Split.preview(vault, user, "/Jobs", {:new, "Careers"})
    assert preview.new_board and preview.into == "Careers"
    refute Repo.get_by(Board, name: "Careers")

    assert {:ok, %{board: board}} = Split.run(vault, user, "/Jobs", {:new, "Careers"})
    assert board.name == "Careers" and board.owner_id == user.id
    assert Repo.get!(Page, ctx.call.id).board_id == board.id
  end

  test "a folder under a mapping's own folder is found from there", ctx do
    %{user: user, kb: kb, hunt: hunt, jobs: jobs} = ctx
    {:ok, vault} = Vaults.create_vault(user, %{"name" => "Only jobs"})
    # A board can't be in two vaults: take it out of GMinds first.
    {:ok, _} = Vaults.delete_vault(ctx.vault)
    {:ok, _} = Vaults.add_mapping(vault, user, %{path: "/Work", board: kb, folder: jobs})

    assert Split.vault_path(vault, ctx.acme) == "Work/Acme"
    assert {:ok, result} = Split.run(vault, user, "/Work/Acme", hunt)
    assert result.unchanged == 2
    assert Repo.get!(Page, ctx.call.id).board_id == hunt.id
  end

  describe "refused, with nothing changed" do
    test "a path that is not a folder, or is a mapping already", ctx do
      %{user: user, hunt: hunt, vault: vault} = ctx

      assert {:error, :not_found, message} = Split.run(vault, user, "/Nope", hunt)
      assert message =~ "no folder at /Nope"

      assert {:error, :unprocessable_entity, message} = Split.run(vault, user, "/", hunt)
      assert message =~ "is a mapping already"
    end

    test "a board in another vault, and nothing moves", ctx do
      %{user: user, hunt: hunt, vault: vault} = ctx
      {:ok, other} = Vaults.create_vault(user, %{"name" => "Other"})
      {:ok, _} = Vaults.add_mapping(other, user, %{path: "/", board: hunt})

      assert {:error, :unprocessable_entity, message} = Split.run(vault, user, "/Jobs", hunt)
      assert message =~ "already in another vault"
      assert Repo.get!(Page, ctx.plan.id).board_id == ctx.kb.id
      assert Repo.get(Folder, ctx.jobs.id)
    end

    test "a board you can't write to", ctx do
      %{user: user, vault: vault} = ctx
      owner = user_fixture("split-owner@example.com")
      theirs = board_fixture(%{"name" => "Theirs", "code" => "thrs"}, owner: owner)
      share_fixture(theirs, user, "read")

      assert {:error, :forbidden, _} = Split.run(vault, user, "/Jobs", theirs)
      assert Repo.get!(Page, ctx.plan.id).board_id == ctx.kb.id
    end

    test "the folder's own board, or a blank new name", ctx do
      %{user: user, kb: kb, vault: vault} = ctx
      assert {:error, :unprocessable_entity, _} = Split.run(vault, user, "/Jobs", kb)
      assert {:error, :unprocessable_entity, _} = Split.run(vault, user, "/Jobs", {:new, "  "})
    end
  end

  test "vault_path is nil for a folder no mapping holds", ctx do
    %{user: user, hunt: hunt, vault: vault} = ctx
    {:ok, loose} = Wiki.create_folder(hunt, %{"name" => "Loose"})
    assert Split.vault_path(vault, loose) == nil
    assert Split.vault_path(vault, ctx.acme) == "Jobs/Acme"
    _ = user
  end
end
