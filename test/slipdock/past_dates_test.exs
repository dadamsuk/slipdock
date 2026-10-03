defmodule Slipdock.PastDatesTest do
  @moduledoc """
  Two different facts about two different dates, which the old single "slip"
  conflated: how far the subcards run past the card's *own* dates, and how far
  past its own due date the card is *today*. A card can be past its due date
  with every subcard still ahead of schedule.
  """
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.Boards
  alias Slipdock.Boards.Card

  setup do
    owner = user_fixture("owner@example.com")
    {:ok, board} = Boards.create_board(%{"name" => "Delivery"}, owner_id: owner.id)
    board = Boards.get_board!(board.id)

    {:ok, template} =
      Boards.create_template(%{
        "name" => "T#{System.unique_integer([:positive])}",
        "columns" => [%{"name" => "Open"}, %{"name" => "Done", "category" => "done"}]
      })

    %{board: board, column: hd(board.columns), template: template}
  end

  defp epic(ctx, attrs, kids) do
    {:ok, card} = Boards.create_card(ctx.column, attrs)
    {:ok, sub} = Boards.create_sub_board(card, ctx.template)
    sub = Boards.get_board!(sub.id)

    for k <- kids, do: {:ok, _} = Boards.create_card(hd(sub.columns), k)

    Boards.get_card!(card.id)
  end

  test "subcards ending late count against the due date only", ctx do
    card =
      epic(ctx, %{"title" => "Epic", "due_date" => ~D[2026-09-29]}, [
        %{"title" => "a", "start_date" => ~D[2026-09-28], "due_date" => ~D[2026-10-30]}
      ])

    assert Card.due_slip(card) == 31
    # No start date of its own, so nothing for the subcards to begin after.
    assert Card.start_slip(card) == 0
  end

  test "subcards beginning late count against the start date only", ctx do
    card =
      epic(ctx, %{"title" => "Epic", "start_date" => ~D[2026-09-01]}, [
        %{"title" => "a", "start_date" => ~D[2026-09-11], "due_date" => ~D[2026-09-20]}
      ])

    assert Card.start_slip(card) == 10
    assert Card.due_slip(card) == 0
  end

  test "both are reported when both run late", ctx do
    card =
      epic(
        ctx,
        %{"title" => "Epic", "start_date" => ~D[2026-09-01], "due_date" => ~D[2026-09-29]},
        [%{"title" => "a", "start_date" => ~D[2026-09-06], "due_date" => ~D[2026-10-30]}]
      )

    assert Card.start_slip(card) == 5
    assert Card.due_slip(card) == 31
  end

  test "a card with no dates of its own has neither", ctx do
    card =
      epic(ctx, %{"title" => "Epic"}, [
        %{"title" => "a", "start_date" => ~D[2026-09-01], "due_date" => ~D[2026-10-30]}
      ])

    assert Card.start_slip(card) == 0
    assert Card.due_slip(card) == 0
  end

  describe "days_past_due/2 is about today, not the subcards" do
    test "counts from the card's own due date", ctx do
      {:ok, card} =
        Boards.create_card(ctx.column, %{"title" => "Late", "due_date" => ~D[2026-09-29]})

      assert Card.days_past_due(card, ~D[2026-10-02]) == 3
      assert Card.days_past_due(card, ~D[2026-09-29]) == 0
      assert Card.days_past_due(card, ~D[2026-09-01]) == 0
    end

    test "a completed card is not past anything", ctx do
      {:ok, card} =
        Boards.create_card(ctx.column, %{
          "title" => "Done",
          "due_date" => ~D[2026-09-29],
          "completed" => true
        })

      assert Card.days_past_due(card, ~D[2026-10-02]) == 0
    end

    test "the two numbers are independent", ctx do
      # Past its own due date by 3, while its subcard is nowhere near late.
      card =
        epic(ctx, %{"title" => "Epic", "due_date" => ~D[2026-09-29]}, [
          %{"title" => "a", "due_date" => ~D[2026-09-20]}
        ])

      assert Card.days_past_due(card, ~D[2026-10-02]) == 3
      assert Card.due_slip(card) == 0
    end
  end

  describe "the wording" do
    test "names the date it is measured from" do
      assert SlipdockWeb.SlipdockComponents.past_date_label(:due, 31) == "31 days past due date"
      assert SlipdockWeb.SlipdockComponents.past_date_label(:start, 5) == "5 days past start date"
      assert SlipdockWeb.SlipdockComponents.past_date_label(:due, 1) == "1 day past due date"
    end

    test "says neither overdue nor slipped" do
      for text <- [
            SlipdockWeb.SlipdockComponents.past_date_label(:due, 31),
            SlipdockWeb.SlipdockComponents.past_date_label(:start, 5),
            SlipdockWeb.SlipdockComponents.past_date_detail(:due, 31, ~D[2026-10-30])
          ] do
        refute text =~ ~r/overdue|slip/i
      end
    end
  end
end
