defmodule Slipdock.WikiFolderMoveTest do
  @moduledoc """
  A folder moved to another board with everything under it (#745): nested
  folders, the pages at home in them and the pages under those, their
  files; filing elsewhere kept or dropped; the refusals; all or nothing; and
  the dry run's report.
  """
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Repo, Vaults, Wiki}
  alias Slipdock.Boards.Comment
  alias Slipdock.Wiki.{Change, Folder, FolderMove, Page, Placement, Placements}

  setup do
    user = user_fixture()
    kb = board_fixture(%{"name" => "Keystone", "code" => "kbf"}, owner: user)
    hunt = board_fixture(%{"name" => "Journal Desk", "code" => "huntf"}, owner: user)
    {:ok, jobs} = Wiki.create_folder(kb, %{"name" => "Journal"})
    {:ok, acme} = Wiki.create_folder(kb, %{"name" => "Acme", "parent_id" => jobs.id})
    {:ok, beta} = Wiki.create_folder(kb, %{"name" => "Beta", "parent_id" => jobs.id})

    {:ok, top} =
      Wiki.create_page(kb, %{"title" => "Search plan", "folder_id" => jobs.id}, user: user)

    {:ok, top} = Wiki.update_page(top, %{"body" => "v2"}, user: user)

    {:ok, call} =
      Wiki.create_page(kb, %{"title" => "Call", "folder_id" => acme.id}, user: user)

    {:ok, child} =
      Wiki.create_page(kb, %{"title" => "Follow-up", "parent_id" => call.id}, user: user)

    {:ok, stays} = Wiki.create_page(kb, %{"title" => "Elsewhere"}, user: user)

    %{
      user: user,
      kb: kb,
      hunt: hunt,
      jobs: jobs,
      acme: acme,
      beta: beta,
      top: top,
      call: call,
      child: child,
      stays: stays
    }
  end

  defp page(id), do: Repo.get!(Page, id)
  defp folder(id), do: Repo.get(Folder, id)

  test "moves nested folders and their pages, keeping codes, history and comments", ctx do
    %{user: user, kb: kb, hunt: hunt, jobs: jobs, acme: acme, beta: beta} = ctx
    Repo.insert!(%Comment{page_id: ctx.call.id, body: "went well"})
    revisions = length(Wiki.list_revisions(ctx.top))

    assert {:ok, %{folder: moved, report: report}} = FolderMove.to_board(jobs, hunt, user)

    assert moved.id == jobs.id and moved.board_id == hunt.id and is_nil(moved.parent_id)
    assert %{board_id: hid, parent_id: pid} = folder(acme.id)
    assert hid == hunt.id and pid == jobs.id
    assert folder(beta.id).board_id == hunt.id
    # Same order under the moved folder.
    assert [a, b] =
             Repo.all(from(f in Folder, where: f.parent_id == ^jobs.id, order_by: f.position))

    assert {a.name, b.name} == {"Acme", "Beta"}

    for p <- [ctx.top, ctx.call, ctx.child] do
      moved = page(p.id)
      assert moved.board_id == hunt.id
      assert moved.code == p.code
    end

    assert page(ctx.top.id).folder_id == jobs.id
    assert page(ctx.call.id).folder_id == acme.id
    assert page(ctx.child.id).parent_id == ctx.call.id
    assert length(Wiki.list_revisions(page(ctx.top.id))) == revisions
    assert Repo.aggregate(from(c in Comment, where: c.page_id == ^ctx.call.id), :count) == 1

    # What was not in it stays put.
    assert page(ctx.stays.id).board_id == kb.id
    assert report.pages == 3 and report.folders == 3

    # Both boards' change feeds name every page and folder that moved.
    for board <- [kb.id, hunt.id], id <- [ctx.top.id, ctx.call.id, ctx.child.id] do
      assert Repo.exists?(
               from(c in Change,
                 where: c.board_id == ^board and c.subject == "page" and c.subject_id == ^id
               )
             )
    end
  end

  test "under a parent folder on the target, after what is there already", ctx do
    %{user: user, hunt: hunt, jobs: jobs} = ctx
    {:ok, archive} = Wiki.create_folder(hunt, %{"name" => "Archive"})
    {:ok, _first} = Wiki.create_folder(hunt, %{"name" => "First", "parent_id" => archive.id})

    assert {:ok, %{folder: moved}} = FolderMove.to_board(jobs, hunt, user, parent: archive)
    assert moved.parent_id == archive.id
    assert moved.position == 1
    assert Wiki.folder_path(moved) == "Archive/Journal"
  end

  test "contents: what is in it lands at the target's top, and the folder goes", ctx do
    %{user: user, kb: kb, hunt: hunt, jobs: jobs, acme: acme} = ctx

    assert {:ok, %{folder: nil}} = FolderMove.to_board(jobs, hunt, user, contents: true)

    assert is_nil(folder(jobs.id))
    assert %{board_id: hid, parent_id: nil} = folder(acme.id)
    assert hid == hunt.id
    assert %{board_id: ^hid, folder_id: nil} = page(ctx.top.id)
    assert page(ctx.call.id).folder_id == acme.id
    refute Repo.exists?(from(f in Folder, where: f.board_id == ^kb.id))
  end

  test "a slug taken on the target gets a number", ctx do
    %{user: user, hunt: hunt, jobs: jobs} = ctx
    {:ok, other} = Wiki.create_folder(hunt, %{"name" => "Old"})
    Repo.update_all(from(f in Folder, where: f.id == ^other.id), set: [slug: "acme"])

    assert {:ok, _} = FolderMove.to_board(jobs, hunt, user)
    assert folder(ctx.acme.id).slug == "acme-2"
  end

  describe "filing in several folders" do
    test "outside a vault, filing across boards is taken away", ctx do
      %{user: user, kb: kb, hunt: hunt, jobs: jobs} = ctx
      {:ok, other} = Wiki.create_folder(kb, %{"name" => "Other"})
      {:ok, _} = Placements.add(ctx.top, other, user)
      {:ok, _} = Placements.add(ctx.stays, jobs, user)

      assert {:ok, report} = FolderMove.preview(jobs, hunt, user)
      assert report.filing_dropped == 2

      assert {:ok, _} = FolderMove.to_board(jobs, hunt, user)
      assert Repo.aggregate(Placement, :count) == 0
    end

    test "in one vault, only the folder's own filing moves, and the rest is kept", ctx do
      %{user: user, kb: kb, hunt: hunt, jobs: jobs} = ctx
      {:ok, vault} = Vaults.create_vault(user, %{"name" => "Brain"})
      {:ok, _} = Vaults.add_mapping(vault, user, %{path: "/", board: kb})
      {:ok, _} = Vaults.add_mapping(vault, user, %{path: "/Plans", board: hunt})
      {:ok, other} = Wiki.create_folder(kb, %{"name" => "Other"})
      {:ok, _} = Placements.add(ctx.top, other, user)
      {:ok, _} = Placements.add(ctx.stays, jobs, user)

      assert {:ok, %{report: %{filing_dropped: 0}}} = FolderMove.to_board(jobs, hunt, user)

      # The moved page is still also in Keystone's Other; the page that
      # stayed is still also in Journal, now on Journal Desk.
      assert Enum.map(Placements.folders(page(ctx.top.id)), & &1.id) == [other.id]
      assert Enum.map(Placements.folders(page(ctx.stays.id)), & &1.id) == [jobs.id]
    end
  end

  test "a page filed here under a parent page that stays, stays with it", ctx do
    %{user: user, kb: kb, hunt: hunt, jobs: jobs} = ctx

    {:ok, under} =
      Wiki.create_page(
        kb,
        %{"title" => "Odd one", "parent_id" => ctx.stays.id, "folder_id" => jobs.id},
        user: user
      )

    assert {:ok, %{left_behind: ["Odd one"]}} = FolderMove.preview(jobs, hunt, user)
    assert {:ok, _} = FolderMove.to_board(jobs, hunt, user)
    assert %{board_id: kid, folder_id: nil} = page(under.id)
    assert kid == kb.id
  end

  test "tags carry by name, and the rest are reported dropped", ctx do
    %{user: user, kb: kb, hunt: hunt, jobs: jobs} = ctx
    ops = tag_fixture(kb, "Ops")
    _theirs = tag_fixture(hunt, "ops")
    alone = tag_fixture(kb, "KB only")
    {:ok, _} = Wiki.set_tags(ctx.top, [ops, alone])

    assert {:ok, report} = FolderMove.preview(jobs, hunt, user)
    assert report.tags == %{carried: ["Ops"], dropped: ["KB only"]}

    assert {:ok, _} = FolderMove.to_board(jobs, hunt, user)

    assert [%{name: "ops"}] =
             page(ctx.top.id) |> Repo.preload(:tags, force: true) |> Map.fetch!(:tags)
  end

  test "the dry run reports per folder and changes nothing", ctx do
    %{user: user, kb: kb, hunt: hunt, jobs: jobs} = ctx
    {:ok, _} = Wiki.create_page(hunt, %{"title" => "Search plan"}, user: user)

    assert {:ok, report} = FolderMove.preview(jobs, hunt, user, contents: true)

    assert report.into == "Journal Desk"
    assert report.folders == 2
    assert report.pages == 3

    assert report.per_folder == [
             %{path: "Journal", pages: 1},
             %{path: "Journal/Acme", pages: 2},
             %{path: "Journal/Beta", pages: 0}
           ]

    # Landing at Journal Desk's top beside a page of the same title.
    assert report.title_clashes == ["Search plan"]
    assert page(ctx.top.id).board_id == kb.id
    assert folder(jobs.id).board_id == kb.id
  end

  test "the wiki files kept in the folders move with them", ctx do
    %{user: user, hunt: hunt, jobs: jobs, acme: acme} = ctx
    source = Path.join(System.tmp_dir!(), "folder-move-#{System.unique_integer([:positive])}.png")
    File.write!(source, "not really a png")
    on_exit(fn -> File.rm(source) end)
    {:ok, file} = Wiki.Files.create(ctx.kb, %{name: "logo.png", folder_id: acme.id}, source, user)

    assert {:ok, %{report: %{files: 1}}} = FolderMove.to_board(jobs, hunt, user)
    assert %{board_id: hid, folder_id: fid} = Repo.get!(Slipdock.Wiki.WikiFile, file.id)
    assert {hid, fid} == {hunt.id, acme.id}
  end

  describe "refused, with nothing moved" do
    test "to a board the user can't write to", ctx do
      %{user: user, jobs: jobs} = ctx
      owner = user_fixture("other-owner@example.com")
      theirs = board_fixture(%{"name" => "Theirs", "code" => "thrf"}, owner: owner)
      share_fixture(theirs, user, "read")

      assert {:error, :forbidden, _} = FolderMove.to_board(jobs, theirs, user)
      assert {:error, :forbidden, _} = FolderMove.preview(jobs, theirs, user)
      assert folder(jobs.id).board_id == ctx.kb.id
    end

    test "by someone who can only read the source", ctx do
      %{user: user, hunt: hunt, jobs: jobs} = ctx
      reader = user_fixture("reader@example.com")
      share_fixture(ctx.kb, reader, "read")
      share_fixture(hunt, reader, "write")

      assert {:error, :forbidden, _} = FolderMove.to_board(jobs, hunt, reader)
      assert {:ok, _} = FolderMove.preview(jobs, hunt, user)
    end

    test "when a folder of that name is already where it would land", ctx do
      %{user: user, hunt: hunt, jobs: jobs} = ctx
      {:ok, _} = Wiki.create_folder(hunt, %{"name" => "journal"})

      assert {:error, :unprocessable_entity, message} = FolderMove.to_board(jobs, hunt, user)
      assert message =~ "Journal Desk already has a folder named Journal at its top"

      # Its contents would land beside Acme and Beta, which is clear.
      assert {:ok, _} = FolderMove.preview(jobs, hunt, user, contents: true)
      {:ok, _} = Wiki.create_folder(hunt, %{"name" => "Acme"})

      assert {:error, :unprocessable_entity, message} =
               FolderMove.preview(jobs, hunt, user, contents: true)

      assert message =~ "folder named Acme"
    end

    test "to its own board, or into a folder on another board", ctx do
      %{user: user, kb: kb, hunt: hunt, jobs: jobs} = ctx
      assert {:error, :unprocessable_entity, _} = FolderMove.to_board(jobs, kb, user)
      {:ok, other} = Wiki.create_folder(kb, %{"name" => "Other"})

      assert {:error, :unprocessable_entity, _} =
               FolderMove.to_board(jobs, hunt, user, parent: other)
    end

    test "while a vault maps onto a folder in it", ctx do
      %{user: user, kb: kb, hunt: hunt, jobs: jobs, acme: acme} = ctx
      {:ok, vault} = Vaults.create_vault(user, %{"name" => "Brain"})
      {:ok, _} = Vaults.add_mapping(vault, user, %{path: "/Acme", board: kb, folder: acme})

      assert {:error, :unprocessable_entity, message} = FolderMove.to_board(jobs, hunt, user)
      assert message =~ "Acme is mapped into a vault at /Acme"
    end
  end
end
