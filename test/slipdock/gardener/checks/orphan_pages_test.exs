defmodule Slipdock.Gardener.Checks.OrphanPagesTest do
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures
  import Slipdock.GardenerHelpers

  alias Slipdock.Gardener
  alias Slipdock.Gardener.Checks.OrphanPages
  alias Slipdock.Wiki
  alias Slipdock.Wiki.Page

  setup do
    owner = user_fixture()
    board = board_fixture(%{}, owner: owner)
    %{owner: owner, board: board}
  end

  defp page(board, owner, attrs, days_old \\ 40) do
    page = page_fixture(board, attrs, user: owner)
    at = DateTime.add(DateTime.utc_now(:second), -days_old * 86_400)

    Repo.update_all(from(p in Page, where: p.id == ^page.id),
      set: [inserted_at: at, updated_at: at]
    )

    Repo.reload!(page)
  end

  defp found(board, opts \\ []),
    do: board |> then(&find(OrphanPages, &1, opts)) |> Enum.flat_map(& &1.subject["pages"])

  test "an old page nothing links to is archived", %{board: board, owner: owner} do
    lonely = page(board, owner, %{"title" => "Lonely"})

    assert [finding] = find(OrphanPages, board)
    assert finding.subject == %{"pages" => [lonely.id]}
    assert finding.proposal == [%{"op" => "archive", "page" => lonely.id}]
    assert finding.explanation =~ "“Lonely” has nothing linking to it"
  end

  test "the threshold: a page younger than 30 days is left alone", %{board: board, owner: owner} do
    young = page(board, owner, %{"title" => "Young"}, 29)
    assert found(board) == []
    assert found(board, settings: %{"days" => 20}) == [young.id]
  end

  test "a backlink from a live page saves it; from an archived one doesn't", %{
    board: board,
    owner: owner
  } do
    target = page(board, owner, %{"title" => "Target"})
    linker = page_fixture(board, %{"title" => "Linker", "body" => "See [[Target]]."}, user: owner)
    refute target.id in found(board)

    {:ok, _} = Wiki.archive_page(linker)
    assert target.id in found(board)
  end

  test "pinned, templates, drafts, pages placed on a list are excluded", %{
    board: board,
    owner: owner
  } do
    column = hd(board.columns)
    card = card_fixture(column)
    pinned = page(board, owner, %{"title" => "Pinned"})
    {:ok, _} = Wiki.pin(pinned, {:card, card})
    page(board, owner, %{"title" => "Template", "template" => true})
    page(board, owner, %{"title" => "Draft", "status" => "draft"})
    placed = page(board, owner, %{"title" => "Placed"})
    {:ok, _} = Wiki.place(placed, column)

    assert found(board) == []
  end

  test "a page filed in a folder is found from it, not an orphan", %{board: board, owner: owner} do
    {:ok, folder} = Wiki.create_folder(board, %{"name" => "Loop logs"})
    page(board, owner, %{"title" => "Pass log #1", "folder_id" => folder.id})
    lonely = page(board, owner, %{"title" => "Loose"})
    assert found(board) == [lonely.id]
  end

  test "folder indexes and pages with pages beneath are excluded", %{board: board, owner: owner} do
    {:ok, folder} = Wiki.create_folder(board, %{"name" => "Ops"})
    page(board, owner, %{"title" => "Ops", "folder_id" => folder.id})
    page(board, owner, %{"title" => "README"})
    parent = page(board, owner, %{"title" => "Parent"})

    page_fixture(board, %{"title" => "Child", "parent_id" => parent.id, "body" => ""},
      user: owner
    )

    # The child is too young to count; the other three are never orphans.
    assert found(board) == []
    assert parent
  end

  test "a page that links to a card shows in its Docs and is not an orphan", %{
    board: board,
    owner: owner
  } do
    card = card_fixture(hd(board.columns))
    page(board, owner, %{"title" => "About it", "body" => "For ##{card.id}."})
    assert found(board) == []
  end

  test "filing into a folder is on offer for a page in none", %{board: board, owner: owner} do
    {:ok, folder} = Wiki.create_folder(board, %{"name" => "Notes"})
    lonely = page(board, owner, %{"title" => "Lonely"})

    assert [%{alternatives: alts}] = find(OrphanPages, board)

    assert alts == %{
             "file into Notes" => [
               %{"op" => "file_page", "page" => lonely.id, "folder" => folder.id}
             ]
           }

    {:ok, _} = Gardener.run(board, only: ["orphan_pages"])
    [s] = Gardener.list_open(board)
    {:ok, _} = Gardener.apply(s, owner, choice: "file into Notes")
    assert Repo.reload!(lonely).folder_id == folder.id
  end
end
