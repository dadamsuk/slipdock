defmodule Slipdock.ChecklistActivityTest do
  @moduledoc """
  Checklist changes are in the activity log (#481): adding, ticking,
  unticking and removing a tick box each leave a line about the card, and a
  change made in several parts at once leaves one line, not one per item.
  """
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures
  alias Slipdock.Boards

  setup do
    owner = user_fixture("owner@example.com")
    board = board_fixture(%{"name" => "Mine"}, owner: owner)
    card = card_fixture(hd(board.columns), %{"title" => "Ship it"})
    %{board: board, card: card}
  end

  defp checklist_lines(board, card) do
    board.id
    |> Boards.list_activities(50, card.id)
    |> Enum.filter(&(&1.kind == "checklist"))
    |> Enum.map(& &1.message)
  end

  test "adding, ticking, unticking and removing each leave one line", ctx do
    {:ok, item} = Boards.add_checklist_item(ctx.card, "Write it")
    assert checklist_lines(ctx.board, ctx.card) == [~s(added a checklist item to “Ship it”)]

    {:ok, item} = Boards.toggle_checklist_item(item)
    assert hd(checklist_lines(ctx.board, ctx.card)) == ~s(ticked a checklist item on “Ship it”)

    {:ok, item} = Boards.toggle_checklist_item(item.id)
    assert hd(checklist_lines(ctx.board, ctx.card)) == ~s(unticked a checklist item on “Ship it”)

    {:ok, _} = Boards.delete_checklist_item(item.id)
    assert hd(checklist_lines(ctx.board, ctx.card)) == ~s(removed a checklist item from “Ship it”)

    assert length(checklist_lines(ctx.board, ctx.card)) == 4

    assert [%{card_id: card_id, board_id: board_id} | _] =
             Boards.list_activities(ctx.board.id, 1, ctx.card.id)

    assert {card_id, board_id} == {ctx.card.id, ctx.board.id}
  end

  test "log: false leaves the line to log_checklist, which writes one for the lot", ctx do
    {:ok, a} = Boards.add_checklist_item(ctx.card, "One", log: false)
    {:ok, b} = Boards.add_checklist_item(ctx.card, "Two", log: false)
    {:ok, _} = Boards.toggle_checklist_item(a, log: false)
    {:ok, _} = Boards.toggle_checklist_item(b, log: false)
    assert checklist_lines(ctx.board, ctx.card) == []

    :ok = Boards.log_checklist(ctx.card, ticked: 2)
    assert checklist_lines(ctx.board, ctx.card) == [~s(ticked 2 checklist items on “Ship it”)]
  end

  test "several kinds of change in one line, and none when nothing changed", ctx do
    :ok = Boards.log_checklist(ctx.card, added: 0, ticked: 0)
    assert checklist_lines(ctx.board, ctx.card) == []

    :ok = Boards.log_checklist(ctx.card, added: 1, ticked: 2, removed: 0)

    assert checklist_lines(ctx.board, ctx.card) ==
             [~s(changed the checklist on “Ship it”: added 1, ticked 2)]
  end

  test "a page's checklist is logged against the page", ctx do
    page = page_fixture(ctx.board, %{"title" => "Runbook"})
    {:ok, item} = Boards.add_checklist_item(page, "Step one")
    {:ok, _} = Boards.toggle_checklist_item(item)

    lines =
      ctx.board.id
      |> Boards.list_activities(50)
      |> Enum.filter(&(&1.kind == "checklist" and &1.page_id == page.id))
      |> Enum.map(& &1.message)

    assert lines == [
             ~s(ticked a checklist item on “Runbook”),
             ~s(added a checklist item to “Runbook”)
           ]
  end

  test "the narrative tells a checklist line as an edit, not as the card being added" do
    for message <- [
          ~s(added a checklist item to “Ship it”),
          ~s(added 2 checklist items to “Ship it”),
          ~s(ticked a checklist item on “Ship it”)
        ] do
      assert Slipdock.Narrative.classify(%{kind: "checklist", message: message}) == :edited
    end
  end
end
