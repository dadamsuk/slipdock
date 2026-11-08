defmodule SlipdockCLI.WaitingOnMeTest do
  @moduledoc """
  `waiting_on_me` (#2095) in `slipdock card <epic>` and `slipdock board`: a
  `Waiting on you:` line on an epic, and the tree's count on the board.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias SlipdockCLI.Render

  @line "Waiting on you: #2063 (a question), #2075 (3 rejections) and 1 on someone else"

  defp waiting(count, line),
    do: %{"count" => count, "cards" => [], "on_others" => 1, "line" => line}

  defp card(attrs) do
    Map.merge(
      %{
        "id" => 2059,
        "title" => "Epic",
        "board_id" => 3,
        "priority" => "none",
        "blocked" => false,
        "blocked_by" => [],
        "blocks" => [],
        "flags" => [],
        "tags" => [],
        "assignees" => [],
        "checklist" => %{"done" => 0, "total" => 0, "items" => []},
        "comments" => [],
        "attachments" => [],
        "urls" => [],
        "links" => []
      },
      attrs
    )
  end

  defp board(attrs) do
    Map.merge(
      %{
        "id" => 3,
        "name" => "Backlog",
        "code" => "slipdock",
        "color" => "amber",
        "tags" => [],
        "columns" => [
          %{
            "id" => 9,
            "name" => "To Do",
            "cards" => [
              card(%{"position" => 1, "waiting_on_me" => waiting(2, @line)}),
              card(%{
                "id" => 12,
                "title" => "Plain",
                "position" => 2,
                "waiting_on_me" => waiting(0, nil)
              })
            ]
          }
        ]
      },
      attrs
    )
  end

  test "slipdock card on an epic prints the line" do
    out = capture_io(fn -> Render.card(card(%{"waiting_on_me" => waiting(2, @line)})) end)
    assert out =~ @line
  end

  test "slipdock card with nothing waiting prints none" do
    out = capture_io(fn -> Render.card(card(%{"waiting_on_me" => waiting(0, nil)})) end)
    refute out =~ "Waiting on you"
    refute capture_io(fn -> Render.card(card(%{})) end) =~ "Waiting on you"
  end

  test "slipdock board gives the tree's count and each epic's line" do
    out = capture_io(fn -> Render.board(board(%{"waiting_on_me" => waiting(2, nil)})) end)
    assert out =~ "Waiting on you: 2"
    assert out =~ "⏸ " <> @line
    assert length(String.split(out, "⏸")) == 2
  end

  test "slipdock board with nothing on me has no count line" do
    out = capture_io(fn -> Render.board(board(%{"waiting_on_me" => waiting(0, nil)})) end)
    refute out =~ "Waiting on you: 0"
  end
end
