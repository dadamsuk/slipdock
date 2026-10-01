defmodule Slipdock.AssignmentsTest do
  use Slipdock.DataCase, async: false

  import Slipdock.Fixtures
  alias Slipdock.{Accounts, Boards, Swimlanes}
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

    assert Swimlanes.move_ops("assignee", a, to_string(ada.id), "none", %Config{}) ==
             [{:attrs, %{"assignee_id" => nil}}]

    assert Swimlanes.move_ops("assignee", a, "none", to_string(bob.id), %Config{}) ==
             [{:attrs, %{"assignee_id" => bob.id}}]

    assert Enum.map(Boards.list_assigned_cards(ada), & &1.title) == ["A"]
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
