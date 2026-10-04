defmodule Slipdock.AssignmentsTest do
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures
  alias Slipdock.{Accounts, Boards, Swimlanes}
  alias Slipdock.Boards.Card
  alias Slipdock.Swimlanes.Config

  @today ~D[2030-01-15]

  test "cards can be assigned; the assignee axis buckets and moves them" do
    board = board_fixture()
    [col | _] = board.columns
    {:ok, ada} = Accounts.get_or_create_user_by_email("ada@example.com")
    {:ok, bob} = Accounts.get_or_create_user_by_email("bob@example.com")
    a = card_fixture(col, %{"title" => "A", "assignee_id" => ada.id})
    b = card_fixture(col, %{"title" => "B", "assignee_id" => bob.id})
    _c = card_fixture(col, %{"title" => "C"})

    assert Boards.get_card!(a.id).assignee.id == ada.id
    {:ok, _} = Boards.update_card(Boards.get_card!(b.id), %{"assignee_id" => ada.id})

    assert Enum.any?(
             Boards.list_activities(board.id),
             &(&1.message =~ "assigned “B” to ada@example.com")
           )

    {:ok, _} = Boards.update_card(Boards.get_card!(b.id), %{"assignee_id" => nil})
    assert Enum.any?(Boards.list_activities(board.id), &(&1.message =~ "unassigned “B”"))

    grid =
      Swimlanes.grid(
        reload(board),
        %Config{rows: "assignee", cols: "none", empty: "show"},
        @today
      )

    assert Enum.map(grid.rows, &{&1.label, &1.count}) == [
             {"ada@example.com", 1},
             {"Unassigned", 2}
           ]

    a = Boards.get_card!(a.id)

    assert Swimlanes.move_ops("assignee", a, to_string(ada.id), "none", %Config{}) ==
             [{:attrs, %{"assignee_ids" => []}}]

    assert Swimlanes.move_ops("assignee", a, to_string(ada.id), to_string(bob.id), %Config{}) ==
             [{:attrs, %{"assignee_ids" => [bob.id]}}]

    assert Enum.map(Boards.list_assigned_cards(ada), & &1.title) == ["A"]
  end

  test "a card can have several assignees, the first of them the lead" do
    board = board_fixture()
    [col | _] = board.columns
    {:ok, ada} = Accounts.get_or_create_user_by_email("ada@example.com")
    {:ok, bob} = Accounts.get_or_create_user_by_email("bob@example.com")
    {:ok, cy} = Accounts.get_or_create_user_by_email("cy@example.com")

    card = card_fixture(col, %{"title" => "Pair on it", "assignee_ids" => [bob.id, ada.id]})
    card = Boards.get_card!(card.id)
    assert card.assignee_id == bob.id
    assert Enum.map(Card.assignees(card), & &1.id) == [bob.id, ada.id]

    # Adding keeps whoever is there; removing the lead hands it on.
    {:ok, _} = Boards.update_card(card, %{"add_assignee_ids" => [cy.id]})
    card = Boards.get_card!(card.id)
    assert Enum.map(Card.assignees(card), & &1.id) == [bob.id, ada.id, cy.id]

    {:ok, _} = Boards.update_card(card, %{"remove_assignee_ids" => [bob.id]})
    card = Boards.get_card!(card.id)
    assert card.assignee_id == ada.id
    assert Enum.sort(Enum.map(Card.assignees(card), & &1.id)) == Enum.sort([ada.id, cy.id])

    assert Enum.any?(
             Boards.list_activities(board.id),
             &(&1.message =~ "assigned “Pair on it” to ada@example.com, cy@example.com")
           )

    # Everybody on it finds it, in the filters and in their own work.
    assert [%{id: id}] = Boards.list_cards(reload(board), %{"assignee" => "cy@example.com"})
    assert id == card.id
    assert Boards.list_cards(reload(board), %{"assignee" => "bob@example.com"}) == []
    assert Enum.map(Boards.list_assigned_cards(cy), & &1.id) == [card.id]

    # The card sits in each person's lane, and dragging it from one person to
    # another swaps just those two.
    grid = Swimlanes.grid(reload(board), %Config{rows: "assignee", cols: "none"}, @today)

    assert Enum.map(grid.rows, &{&1.label, &1.count}) |> Enum.take(2) ==
             [{"ada@example.com", 1}, {"cy@example.com", 1}]

    assert Swimlanes.move_ops("assignee", card, to_string(cy.id), to_string(bob.id), %Config{}) ==
             [{:attrs, %{"assignee_ids" => [ada.id, bob.id]}}]

    # A bare assignee_id is what a single-person caller sends, and still means
    # "this person and nobody else".
    {:ok, _} = Boards.update_card(card, %{"assignee_id" => bob.id})
    assert Enum.map(Card.assignees(Boards.get_card!(card.id)), & &1.id) == [bob.id]

    {:ok, _} = Boards.update_card(Boards.get_card!(card.id), %{"assignee_ids" => []})
    card = Boards.get_card!(card.id)
    assert card.assignee_id == nil and Card.assignees(card) == []
  end

  test "the rolled-up schedule axis places a parent by its subcards' dates" do
    ctx = tree_fixture()
    board = Boards.get_board!(ctx.board.id)
    config = %Config{rows: "schedule", cols: "none", unit: "month"}
    grid = Swimlanes.grid(board, config, @today)
    # Epic keeps its own due (Jan); Late is Jan too; Stuck and Loose have no date at all.
    assert Enum.map(grid.rows, &{&1.label, &1.count}) == [{"Jan 2030", 2}, {"No due date", 2}]

    # Take the epic's own date away: it lands where its subcards end (20 Jan, still Jan)
    # and the sub-board's C lands in February through E.
    {:ok, _} = Boards.update_card(ctx.epic, %{"due_date" => nil})
    sub = Boards.get_board!(ctx.sub.id)
    grid = Swimlanes.grid(sub, %{config | unit: "quarter"}, @today)
    assert Enum.map(grid.rows, &{&1.label, &1.count}) == [{"Q1 2030", 2}]
    grid = Swimlanes.grid(sub, %{config | unit: "month"}, @today)

    assert Enum.map(grid.rows, &{&1.label, Enum.map(List.flatten(&1.cells), fn c -> c.title end)}) ==
             [{"Jan 2030", ["B", "C"]}]

    assert Swimlanes.move_ops("schedule", ctx.c, "2030-01-01", "2030-03-01", config) ==
             [{:attrs, %{"due_date" => ~D[2030-03-01]}}]
  end
end
