defmodule Slipdock.ChecklistOrderTest do
  @moduledoc """
  `Boards.Checklists.move_checklist_item/2` (#1752): a tick box moves before another of
  the same card or page, or to the end, and the new order is what the card
  (or page) loads from then on.
  """
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures
  alias Slipdock.{Boards, Repo, Wiki}

  setup do
    owner = user_fixture("order-owner@example.com")
    board = board_fixture(%{"name" => "Order"}, owner: owner)
    card = card_fixture(hd(board.columns), %{"title" => "Ordered"})

    items =
      for text <- ~w(one two three four) do
        {:ok, item} = Boards.Checklists.add_checklist_item(card, text)
        item
      end

    %{owner: owner, board: board, card: card, items: items}
  end

  defp texts(items), do: Enum.map(items, & &1.text)

  defp loaded(card),
    do: card |> Repo.preload(:checklist_items, force: true) |> Map.fetch!(:checklist_items)

  test "before another item, later in the list", %{card: card, items: [one, _, three, _]} do
    assert {:ok, items} = Boards.Checklists.move_checklist_item(one, three.id)
    assert texts(items) == ~w(two one three four)
    assert Enum.map(items, & &1.position) == [0, 1, 2, 3]
    assert texts(loaded(card)) == ~w(two one three four)
  end

  test "before another item, earlier in the list, by a string id",
       %{card: card, items: [one, _, _, four]} do
    assert {:ok, items} = Boards.Checklists.move_checklist_item(four, to_string(one.id))
    assert texts(items) == ~w(four one two three)
    assert texts(loaded(card)) == ~w(four one two three)
  end

  test "to the end, with nil or an empty string", %{card: card, items: [one, two, _, _]} do
    assert {:ok, items} = Boards.Checklists.move_checklist_item(one, nil)
    assert texts(items) == ~w(two three four one)

    assert {:ok, _} = Boards.Checklists.move_checklist_item(Repo.reload!(two), "")
    assert texts(loaded(card)) == ~w(three four one two)
  end

  test "before itself leaves the order alone", %{card: card, items: [_, two, _, _]} do
    assert {:ok, items} = Boards.Checklists.move_checklist_item(two, two.id)
    assert texts(items) == ~w(one two three four)
    assert texts(loaded(card)) == ~w(one two three four)
  end

  test "an item of another card is refused, and nothing moves", ctx do
    other = card_fixture(hd(ctx.board.columns), %{"title" => "Other"})
    {:ok, theirs} = Boards.Checklists.add_checklist_item(other, "theirs")
    [one | _] = ctx.items

    assert {:error, :not_found} = Boards.Checklists.move_checklist_item(one, theirs.id)
    assert {:error, :not_found} = Boards.Checklists.move_checklist_item(theirs, one.id)
    assert {:error, :not_found} = Boards.Checklists.move_checklist_item(one, "not-an-id")
    assert texts(loaded(ctx.card)) == ~w(one two three four)
    assert texts(loaded(other)) == ~w(theirs)
  end

  test "a page's checklist reorders the same way, apart from the card's", ctx do
    {:ok, page} = Wiki.create_page(ctx.board, %{"title" => "Spec"}, user: ctx.owner)
    {:ok, a} = Boards.Checklists.add_checklist_item(page, "a")
    {:ok, b} = Boards.Checklists.add_checklist_item(page, "b")

    assert {:ok, items} = Boards.Checklists.move_checklist_item(b, a.id)
    assert texts(items) == ~w(b a)
    assert texts(loaded(page)) == ~w(b a)
    assert {:error, :not_found} = Boards.Checklists.move_checklist_item(a, hd(ctx.items).id)
    assert texts(loaded(ctx.card)) == ~w(one two three four)
  end

  test "a new order leaves no activity line", ctx do
    before = length(Boards.ActivityLog.list_activities(ctx.board.id, 50, ctx.card.id))
    {:ok, _} = Boards.Checklists.move_checklist_item(hd(ctx.items), nil)
    assert length(Boards.ActivityLog.list_activities(ctx.board.id, 50, ctx.card.id)) == before
  end
end
