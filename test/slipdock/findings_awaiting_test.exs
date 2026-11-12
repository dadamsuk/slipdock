defmodule Slipdock.FindingsAwaitingTest do
  @moduledoc """
  What a board's findings leave for a person (#2123): the open garden
  proposals drafted from them, on the tree's root, and nothing else.
  """
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Boards, Repo}
  alias Slipdock.Findings.Awaiting
  alias Slipdock.Gardener.Suggestion

  defp proposal(board, subject, attrs \\ []) do
    %Suggestion{
      board_id: board.id,
      check: "proposal",
      fingerprint: "p#{System.unique_integer([:positive])}",
      explanation: "add a rule",
      subject: subject
    }
    |> struct(attrs)
    |> Repo.insert!()
  end

  test "open proposals drafted from findings, oldest first, read from any board of the tree" do
    owner = user_fixture()
    board = board_fixture(%{"name" => "Root"}, owner: owner)
    card = card_fixture(hd(board.columns), %{"title" => "Epic"})
    {:ok, t} = Boards.Templates.find_template(nil, "Simple")
    {:ok, sub} = sub_board(card, t)
    other = board_fixture(%{"name" => "Other"}, owner: owner)

    first = proposal(board, %{"findings" => [1, 2]})
    second = proposal(board, %{"findings" => [3], "pages" => [9]})
    proposal(board, %{"findings" => [4]}, state: "applied")
    proposal(board, %{"findings" => [5]}, state: "dismissed")
    proposal(board, %{"pages" => [9]})
    proposal(board, %{"findings" => [6]}, check: "stale_card")
    proposal(other, %{"findings" => [7]})

    assert Enum.map(Awaiting.proposals(board), & &1.id) == [first.id, second.id]

    assert Enum.map(Awaiting.proposals(Boards.get_board!(sub.id)), & &1.id) == [
             first.id,
             second.id
           ]

    assert Awaiting.count(board) == 2
    assert Awaiting.findings(first) == [1, 2]
    assert Awaiting.findings(%Suggestion{subject: %{"findings" => "x"}}) == []
    assert Awaiting.count(board_fixture(%{"name" => "Empty"}, owner: owner)) == 0
  end
end
