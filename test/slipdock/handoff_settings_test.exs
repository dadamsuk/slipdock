defmodule Slipdock.HandoffSettingsTest do
  @moduledoc """
  A board's own name for "Left off" and its own instructions for drafting a
  handoff (#1212): blank is the default, too long is refused, a sub-board
  takes its parent's, and both travel through a portable export and import.
  """
  # Sync, as the other import tests: imports derive board codes.
  use Slipdock.DataCase, async: false

  import Slipdock.Fixtures

  alias Slipdock.{Boards, Portable}
  alias Slipdock.Boards.Board

  setup do
    owner = user_fixture("owner@example.com")
    board = board_fixture(%{"name" => "Handoffs", "code" => unique_code()}, owner: owner)
    %{owner: owner, board: board}
  end

  test "without its own, a board says Left off and has no instructions of its own", ctx do
    assert ctx.board.handoff_label == nil
    assert Board.handoff_label(ctx.board) == "Left off"
    assert Board.handoff_prompt(ctx.board) == nil
  end

  test "its own are kept trimmed; blank goes back to the default", ctx do
    {:ok, board} =
      Boards.update_board(ctx.board, %{
        "handoff_label" => "  Parked at ",
        "handoff_prompt" => "\n Be brief. \n"
      })

    assert Board.handoff_label(board) == "Parked at"
    assert Board.handoff_prompt(board) == "Be brief."

    {:ok, board} = Boards.update_board(board, %{"handoff_label" => "  ", "handoff_prompt" => ""})
    assert board.handoff_label == nil and board.handoff_prompt == nil
    assert Board.handoff_label(board) == "Left off"
  end

  test "too long is refused", ctx do
    %{label: label, prompt: prompt} = Board.handoff_limits()

    assert {:error, cs} =
             Boards.update_board(ctx.board, %{"handoff_label" => String.duplicate("a", label + 1)})

    assert %{handoff_label: [_]} = errors_on(cs)

    assert {:error, cs} =
             Boards.update_board(ctx.board, %{
               "handoff_prompt" => String.duplicate("a", prompt + 1)
             })

    assert %{handoff_prompt: [_]} = errors_on(cs)

    assert {:ok, _} =
             Boards.update_board(ctx.board, %{"handoff_label" => String.duplicate("a", label)})
  end

  test "a card's subcards take the parent board's", ctx do
    {:ok, board} =
      Boards.update_board(ctx.board, %{"handoff_label" => "Parked", "handoff_prompt" => "Brief."})

    card = card_fixture(hd(board.columns), %{"title" => "Epic"})
    {:ok, t} = Boards.find_template(nil, "Simple")
    {:ok, sub} = Boards.create_sub_board(card, t)

    assert sub.handoff_label == "Parked"
    assert sub.handoff_prompt == "Brief."
  end

  test "an export carries them and an import keeps them, cut to fit", ctx do
    {:ok, board} =
      Boards.update_board(ctx.board, %{"handoff_label" => "Parked", "handoff_prompt" => "Brief."})

    doc = Portable.export(ctx.owner, boards: [board])
    [tree] = doc.boards
    assert tree.root.handoff_label == "Parked" and tree.root.handoff_prompt == "Brief."

    {:ok, report} = Portable.import(ctx.owner, Jason.encode!(doc))
    imported = Boards.get_board!(hd(report.boards).id)
    assert imported.handoff_label == "Parked" and imported.handoff_prompt == "Brief."

    long = put_in(doc, [:boards, Access.at(0), :root, :handoff_label], String.duplicate("b", 100))
    {:ok, report} = Portable.import(ctx.owner, Jason.encode!(long))
    imported = Boards.get_board!(hd(report.boards).id)
    assert imported.handoff_label == String.duplicate("b", Board.handoff_limits().label)
  end
end
