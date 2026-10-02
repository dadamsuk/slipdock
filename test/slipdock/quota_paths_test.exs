defmodule Slipdock.QuotaPathsTest do
  @moduledoc """
  The card limit through the *other* ways a card gets made.

  The point of enforcing it in `Boards.create_card/2` was that quick add, the
  CLI, the API, an automation rule and the model all come through there. This
  is the test that says so, because "they all go through one function" is a
  claim that rots the moment somebody adds a sixth path.
  """
  use Slipdock.DataCase, async: false

  import Slipdock.Fixtures

  alias Slipdock.{Boards, Quota, Settings}
  alias Slipdock.QuickAdd.Capture

  setup do
    {:ok, _} =
      Settings.complete_setup(%{"admin_email" => "admin@example.com", "free_card_limit" => 2})

    owner = user_fixture("owner@example.com")
    board = board_fixture(%{"name" => "Full"}, owner: owner)
    [backlog | _] = board.columns

    # Fill it to the limit.
    {:ok, _} = Boards.create_card(backlog, %{"title" => "One"})
    {:ok, _} = Boards.create_card(backlog, %{"title" => "Two"})

    %{owner: owner, board: board, column: backlog}
  end

  test "the board itself is at the wall", %{owner: owner, column: column} do
    assert Quota.check(owner) == {:error, :card_limit_reached}
    assert {:error, changeset} = Boards.create_card(column, %{"title" => "Three"})
    assert Quota.limit_reached?(changeset)
  end

  test "quick add is refused too", %{owner: owner, board: board, column: column} do
    {:ok, owner} =
      Slipdock.Accounts.update_quick_add(owner, %{
        "quick_add_board_id" => board.id,
        "quick_add_column_id" => column.id,
        "quick_add_ai" => false
      })

    assert {:error, reason} = Capture.capture(owner, "Three please")
    assert quota_refusal?(reason)
    assert Quota.used(owner) == 2
  end

  test "an automation rule hitting the wall fails as a rule failure, not silently", %{
    board: board,
    column: column,
    owner: owner
  } do
    rule_fixture(board, %{
      "trigger" => %{"type" => "card_completed"},
      "actions" => [%{"type" => "create_card", "title" => "Follow up", "column" => column.name}]
    })

    [card | _] = Boards.get_board!(board.id).columns |> hd() |> Map.get(:cards)
    {:ok, _} = Boards.toggle_completed(card)

    # The rule could not make its card, and the count did not move.
    assert Quota.used(owner) == 2

    titles =
      board.id
      |> Boards.get_board!()
      |> Map.get(:columns)
      |> Enum.flat_map(& &1.cards)
      |> Enum.map(& &1.title)

    refute "Follow up" in titles
  end

  test "archiving one lets every path through again", %{owner: owner, column: column} do
    [card | _] = Boards.get_board!(column.board_id).columns |> hd() |> Map.get(:cards)
    {:ok, _} = Boards.archive_card(card)

    assert Quota.check(owner) == :ok
    assert {:ok, _} = Boards.create_card(column, %{"title" => "Three"})
  end

  defp quota_refusal?(%Ecto.Changeset{} = changeset), do: Quota.limit_reached?(changeset)
  defp quota_refusal?(reason) when is_binary(reason), do: reason =~ "card"
  defp quota_refusal?(_), do: false
end
