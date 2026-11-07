defmodule Slipdock.AgenticBuildingPortableTest do
  @moduledoc """
  A board's Agentic Building switch (#2011) goes out with a portable export
  and comes back in; an export from before it turns it on where an agent
  setting is set, as the migration did, and leaves a plain board off.
  """
  # Sync, as the other import tests: imports derive board codes.
  use Slipdock.DataCase, async: false

  import Slipdock.Fixtures

  alias Slipdock.{Boards, Portable}

  defp without_switch(document) do
    update_in(document.boards, fn [t] ->
      [update_in(t.root, &Map.delete(&1, :agentic_building))]
    end)
  end

  test "the switch comes back as it was, on or off" do
    owner = user_fixture("agentic-owner@example.com")
    board = board_fixture(%{"name" => "Agents", "code" => unique_code()}, owner: owner)

    {:ok, board} =
      Boards.update_board(board, %{"agentic_building" => true, "verify_work" => true})

    document = Portable.export(owner, boards: [board])
    [tree] = document.boards
    assert tree.root.agentic_building == true

    {:ok, report} = Portable.import(owner, Jason.encode!(document))
    assert Boards.get_board!(hd(report.boards).id).agentic_building

    # Off with a rule set stays off: that was the owner's choice.
    {:ok, board} = Boards.update_board(board, %{"agentic_building" => false})
    {:ok, report} = Portable.import(owner, Jason.encode!(Portable.export(owner, boards: [board])))
    refute Boards.get_board!(hd(report.boards).id).agentic_building
  end

  test "an export from before it: on where a setting is set, off on a plain board" do
    owner = user_fixture("agentic-old@example.com")
    plain = board_fixture(%{"name" => "Plain", "code" => unique_code()}, owner: owner)
    laned = board_fixture(%{"name" => "Laned", "code" => unique_code()}, owner: owner)
    {:ok, laned} = Boards.update_board(laned, %{"lane_mode" => "advise"})

    {:ok, report} =
      Portable.import(
        owner,
        Jason.encode!(without_switch(Portable.export(owner, boards: [laned])))
      )

    assert Boards.get_board!(hd(report.boards).id).agentic_building

    {:ok, report} =
      Portable.import(
        owner,
        Jason.encode!(without_switch(Portable.export(owner, boards: [plain])))
      )

    refute Boards.get_board!(hd(report.boards).id).agentic_building
  end
end
