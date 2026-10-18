defmodule Slipdock.Gardener.Checks.BrokenLinksTest do
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures
  import Slipdock.GardenerHelpers

  alias Slipdock.Gardener
  alias Slipdock.Gardener.Checks.BrokenLinks

  setup do
    owner = user_fixture()
    board = board_fixture(%{}, owner: owner)
    %{owner: owner, board: board}
  end

  test "a link within two edits of one page is rewritten to it", %{board: board, owner: owner} do
    target = page_fixture(board, %{"title" => "Deploy runbook"}, user: owner)

    linker =
      page_fixture(board, %{"title" => "Notes", "body" => "See [[Deploy runbok]]."}, user: owner)

    assert [finding] = find(BrokenLinks, board)
    assert finding.subject == %{"pages" => [linker.id, target.id]}

    assert finding.proposal == [
             %{
               "op" => "rewrite_link",
               "page" => linker.id,
               "from" => "Deploy runbok",
               "to" => "Deploy runbook"
             }
           ]

    assert finding.explanation =~ "[[Deploy runbok]] on “Notes” leads nowhere"

    {:ok, _} = Gardener.run(board, only: ["broken_links"])
    [s] = Gardener.list_open(board)
    {:ok, _} = Gardener.apply(s, owner)
    assert Repo.reload!(linker).body == "See [[Deploy runbook]]."
  end

  test "an alias matching ignoring case is the page", %{board: board, owner: owner} do
    target =
      page_fixture(
        board,
        %{"title" => "Runbook", "front_matter" => "---\naliases: [How We Ship]\n---\n"},
        user: owner
      )

    page_fixture(board, %{"title" => "Notes", "body" => "[[how we shipp]]"}, user: owner)

    assert [%{proposal: [%{"to" => "Runbook"}]} = f] = find(BrokenLinks, board)
    assert target.id in f.subject["pages"]
  end

  test "the threshold: three edits away is not a match", %{board: board, owner: owner} do
    page_fixture(board, %{"title" => "Deploy runbook"}, user: owner)
    page_fixture(board, %{"title" => "Notes", "body" => "[[Deploy rnbk]]"}, user: owner)
    assert find(BrokenLinks, board) == []
    assert [_] = find(BrokenLinks, board, settings: %{"max_distance" => 3})
  end

  test "two candidates is ambiguous and suggests nothing", %{board: board, owner: owner} do
    page_fixture(board, %{"title" => "Release notes"}, user: owner)
    page_fixture(board, %{"title" => "Release nodes"}, user: owner)
    page_fixture(board, %{"title" => "Notes", "body" => "[[Release notez]]"}, user: owner)
    assert find(BrokenLinks, board) == []
  end

  test "short titles only match exactly", %{board: board, owner: owner} do
    page_fixture(board, %{"title" => "API"}, user: owner)
    page_fixture(board, %{"title" => "Notes", "body" => "[[AWS]]"}, user: owner)
    assert find(BrokenLinks, board) == []
  end

  test "a link that resolves, or matches nothing, is not broken", %{board: board, owner: owner} do
    page_fixture(board, %{"title" => "Runbook"}, user: owner)

    page_fixture(
      board,
      %{"title" => "Notes", "body" => "[[Runbook]] and [[Something else entirely]]"}, user: owner)

    assert find(BrokenLinks, board) == []
  end

  test "several pages with the same typo are one suggestion", %{board: board, owner: owner} do
    page_fixture(board, %{"title" => "Deploy runbook"}, user: owner)
    a = page_fixture(board, %{"title" => "A", "body" => "[[Deploy runbok]]"}, user: owner)
    b = page_fixture(board, %{"title" => "B", "body" => "[[deploy runbok|it]]"}, user: owner)

    assert [finding] = find(BrokenLinks, board)
    assert Enum.map(finding.proposal, & &1["page"]) |> Enum.sort() == Enum.sort([a.id, b.id])
  end

  test "distance/2" do
    assert BrokenLinks.distance("kitten", "sitting") == 3
    assert BrokenLinks.distance("", "abc") == 3
    assert BrokenLinks.distance("same", "same") == 0
  end
end
