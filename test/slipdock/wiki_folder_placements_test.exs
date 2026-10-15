defmodule Slipdock.WikiFolderPlacementsTest do
  @moduledoc """
  One folder in several places (#808, #809): a home parent and placements
  beside it, on the folder's board or across its vault, never inside its own
  subtree, and nothing about a placement ever touching the folder.
  """
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Vaults, Wiki}
  alias Slipdock.Wiki.FolderPlacements

  setup do
    user = user_fixture()
    board = board_fixture(%{"name" => "Brain", "code" => "fplace"}, owner: user)
    jobs = board_fixture(%{"name" => "Journal", "code" => "fpjobs"}, owner: user)
    {:ok, home} = Wiki.create_folder(board, %{"name" => "Home"})
    {:ok, folder} = Wiki.create_folder(board, %{"name" => "Topic", "parent_id" => home.id})
    {:ok, other} = Wiki.create_folder(board, %{"name" => "Other"})

    %{user: user, board: board, jobs: jobs, home: home, folder: folder, other: other}
  end

  defp in_vault(ctx) do
    {:ok, vault} = Vaults.create_vault(ctx.user, %{"name" => "V"})
    {:ok, _} = Vaults.add_mapping(vault, ctx.user, %{path: "/", board: ctx.board})
    {:ok, _} = Vaults.add_mapping(vault, ctx.user, %{path: "/Journal", board: ctx.jobs})
    vault
  end

  defp paths(folders), do: Enum.map(folders, &Wiki.folder_path/1)

  test "a folder is also filed in another, keeps its home, and is listed there", ctx do
    assert {:ok, [placed]} = FolderPlacements.add(ctx.folder, ctx.other, ctx.user)
    assert placed.id == ctx.other.id
    assert placed.board.code == "fplace"
    assert Wiki.get_folder(ctx.folder.id).parent_id == ctx.home.id

    assert [%{id: id}] = FolderPlacements.placed_in(ctx.other, ctx.user)
    assert id == ctx.folder.id
    # Filing it twice is filing it once.
    assert {:ok, [_]} = FolderPlacements.add(ctx.folder, ctx.other, ctx.user)
  end

  test "into its own home parent is refused; moving home to a placement drops it", ctx do
    assert {:error, :unprocessable_entity, msg} =
             FolderPlacements.add(ctx.folder, ctx.home, ctx.user)

    assert msg =~ "home"

    {:ok, _} = FolderPlacements.add(ctx.folder, ctx.other, ctx.user)
    {:ok, moved} = Wiki.update_folder(ctx.folder, %{"parent_id" => ctx.other.id})
    assert FolderPlacements.folders(moved) == []

    {:ok, _} = FolderPlacements.add(moved, ctx.home, ctx.user)
    {:ok, moved} = Wiki.move_folder(moved, ctx.home)
    assert FolderPlacements.folders(moved) == []
  end

  test "a direct cycle is refused: into itself or its own subfolder", ctx do
    {:ok, inner} =
      Wiki.create_folder(ctx.board, %{"name" => "Inner", "parent_id" => ctx.folder.id})

    assert {:error, :unprocessable_entity, msg} =
             FolderPlacements.add(ctx.folder, ctx.folder, ctx.user)

    assert msg =~ "itself"

    assert {:error, :unprocessable_entity, msg} =
             FolderPlacements.add(ctx.folder, inner, ctx.user)

    assert msg =~ "inside “Topic”"
    refute msg =~ "through"
    assert FolderPlacements.folders(ctx.folder) == []
  end

  test "a cycle through another placement is refused, for filing and for moving", ctx do
    # Other is filed inside Topic; Topic may then not be filed in Other, nor
    # in anything under Other.
    {:ok, _} = FolderPlacements.add(ctx.other, ctx.folder, ctx.user)
    {:ok, deep} = Wiki.create_folder(ctx.board, %{"name" => "Deep", "parent_id" => ctx.other.id})

    for target <- [ctx.other, deep] do
      assert {:error, :unprocessable_entity, msg} =
               FolderPlacements.add(ctx.folder, target, ctx.user)

      assert msg =~ "through another placement"
    end

    # Nor moved home under one of them.
    assert {:error, :unprocessable_entity, msg} =
             Wiki.update_folder(ctx.folder, %{"parent_id" => deep.id})

    assert msg =~ "filed inside it"
    assert {:error, :unprocessable_entity, _} = Wiki.move_folder(ctx.folder, ctx.other)
    assert Wiki.get_folder(ctx.folder.id).parent_id == ctx.home.id
  end

  test "only on its own board or a board in the same vault", ctx do
    {:ok, notes} = Wiki.create_folder(ctx.jobs, %{"name" => "Notes"})

    assert {:error, :unprocessable_entity, msg} =
             FolderPlacements.add(ctx.folder, notes, ctx.user)

    assert msg =~ "same vault"

    in_vault(ctx)
    assert {:ok, [placed]} = FolderPlacements.add(ctx.folder, notes, ctx.user)
    assert placed.board.code == "fpjobs"
    # A reader of the target board sees it; with nobody named, only its own board's.
    assert [_] = FolderPlacements.placed_in(notes, ctx.user)
    assert FolderPlacements.placed_in(notes) == []
  end

  test "a cross-vault target is refused even when both boards are in vaults", ctx do
    in_vault(ctx)
    elsewhere = board_fixture(%{"name" => "Elsewhere"}, owner: ctx.user)
    {:ok, v2} = Vaults.create_vault(ctx.user, %{"name" => "V2"})
    {:ok, _} = Vaults.add_mapping(v2, ctx.user, %{path: "/", board: elsewhere})
    {:ok, far} = Wiki.create_folder(elsewhere, %{"name" => "Far"})

    assert {:error, :unprocessable_entity, _} = FolderPlacements.add(ctx.folder, far, ctx.user)
  end

  test "it needs write on both boards", ctx do
    in_vault(ctx)
    {:ok, notes} = Wiki.create_folder(ctx.jobs, %{"name" => "Notes"})
    reader = user_fixture("reader@example.com")
    share_fixture(ctx.board, reader, "write")
    share_fixture(ctx.jobs, reader, "read")

    assert {:error, :forbidden, _} = FolderPlacements.add(ctx.folder, notes, reader)
    # A reader of the target sees a folder placed there by somebody else.
    {:ok, _} = FolderPlacements.add(ctx.folder, notes, ctx.user)
    assert [_] = FolderPlacements.placed_in(notes, reader)

    stranger = user_fixture("stranger@example.com")
    assert {:error, :forbidden, _} = FolderPlacements.add(ctx.folder, ctx.other, stranger)
    assert {:error, :forbidden, _} = FolderPlacements.remove(ctx.folder, notes, stranger)
    assert FolderPlacements.placed_in(notes, stranger) == []
  end

  test "removing a placement leaves the folder and its contents alone", ctx do
    {:ok, page} =
      Wiki.create_page(ctx.board, %{"title" => "Kept", "folder_id" => ctx.folder.id},
        user: ctx.user
      )

    {:ok, _} = FolderPlacements.add(ctx.folder, ctx.other, ctx.user)
    assert {:ok, []} = FolderPlacements.remove(ctx.folder, ctx.other, ctx.user)
    assert Wiki.get_folder(ctx.folder.id).parent_id == ctx.home.id
    assert Wiki.get_page!(page.id).folder_id == ctx.folder.id
    assert {:error, :not_found, _} = FolderPlacements.remove(ctx.folder, ctx.other, ctx.user)
  end

  test "deleting either folder takes the placement with it", ctx do
    {:ok, _} = FolderPlacements.add(ctx.folder, ctx.other, ctx.user)
    {:ok, _} = Wiki.delete_folder(ctx.other)
    assert FolderPlacements.folders(ctx.folder) == []

    {:ok, third} = Wiki.create_folder(ctx.board, %{"name" => "Third"})
    {:ok, _} = FolderPlacements.add(ctx.folder, third, ctx.user)
    {:ok, _} = Wiki.delete_folder(ctx.folder, :purge)
    assert FolderPlacements.placed_in(third) == []
  end

  test "deleting a folder moves its subfolders up, dropping a placement that became home", ctx do
    # Topic is also filed at the top's sibling Other; deleting Home moves
    # Topic to the top — not where it was placed, so the placement stays.
    {:ok, _} = FolderPlacements.add(ctx.folder, ctx.other, ctx.user)
    {:ok, _} = Wiki.delete_folder(ctx.home)
    assert paths(FolderPlacements.folders(Wiki.get_folder(ctx.folder.id))) == ["Other"]

    # Inner, at home in Topic and also filed in Other: Topic moves into Other,
    # then Topic is deleted, so Inner lands in Other — its home now.
    {:ok, inner} =
      Wiki.create_folder(ctx.board, %{"name" => "Inner", "parent_id" => ctx.folder.id})

    {:ok, _} = FolderPlacements.remove(ctx.folder, ctx.other, ctx.user)
    {:ok, _} = FolderPlacements.add(inner, ctx.other, ctx.user)
    {:ok, topic} = Wiki.move_folder(Wiki.get_folder(ctx.folder.id), ctx.other)
    {:ok, _} = Wiki.delete_folder(topic)
    inner = Wiki.get_folder(inner.id)
    assert inner.parent_id == ctx.other.id
    assert FolderPlacements.folders(inner) == []
  end

  describe "moving a folder to another board" do
    test "drops placements the move strands, and says which", ctx do
      {:ok, _} = FolderPlacements.add(ctx.folder, ctx.other, ctx.user)

      assert {:ok, preview} = Wiki.FolderMove.preview(ctx.folder, ctx.jobs, ctx.user)
      assert preview.folder_filing_dropped == [%{folder: "Home/Topic", in: "Other"}]

      assert {:ok, %{report: report}} = Wiki.FolderMove.to_board(ctx.folder, ctx.jobs, ctx.user)
      assert report.folder_filing_dropped == [%{folder: "Home/Topic", in: "Other"}]
      assert FolderPlacements.folders(Wiki.get_folder(ctx.folder.id)) == []
    end

    test "keeps them inside one vault", ctx do
      in_vault(ctx)
      {:ok, _} = FolderPlacements.add(ctx.folder, ctx.other, ctx.user)

      assert {:ok, %{report: report}} = Wiki.FolderMove.to_board(ctx.folder, ctx.jobs, ctx.user)
      assert report.folder_filing_dropped == []
      assert paths(FolderPlacements.folders(Wiki.get_folder(ctx.folder.id))) == ["Other"]
    end

    test "keeps a placement inside the moving subtree", ctx do
      {:ok, a} = Wiki.create_folder(ctx.board, %{"name" => "A", "parent_id" => ctx.folder.id})
      {:ok, b} = Wiki.create_folder(ctx.board, %{"name" => "B", "parent_id" => ctx.folder.id})
      {:ok, _} = FolderPlacements.add(a, b, ctx.user)

      assert {:ok, %{report: report}} = Wiki.FolderMove.to_board(ctx.folder, ctx.jobs, ctx.user)
      assert report.folder_filing_dropped == []
      assert [%{id: id}] = FolderPlacements.folders(Wiki.get_folder(a.id))
      assert id == b.id
    end
  end
end
