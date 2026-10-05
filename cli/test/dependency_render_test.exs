defmodule SlipdockCLI.DependencyRenderTest do
  @moduledoc """
  `card` showing what a card waits on: a card on another board carries that
  board's code, and one on a board the reader can't see comes as the server
  hid it.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias SlipdockCLI.Render

  defp card(blocked_by) do
    %{
      "id" => 12,
      "title" => "Waits",
      "board_id" => 3,
      "blocked" => true,
      "blocked_by" => blocked_by,
      "blocks" => [],
      "flags" => [],
      "tags" => [],
      "assignees" => [],
      "checklist" => %{"done" => 0, "total" => 0, "items" => []},
      "comments" => [],
      "attachments" => [],
      "urls" => [],
      "links" => []
    }
  end

  test "a blocker on the same board is shown without a board code" do
    out =
      capture_io(fn ->
        Render.card(
          card([
            %{
              "id" => 7,
              "title" => "Here",
              "board_id" => 3,
              "board" => "home",
              "completed" => false
            }
          ])
        )
      end)

    assert out =~ "#7 Here (open)"
    refute out =~ "home #7"
  end

  test "a blocker on another board is prefixed with its code" do
    out =
      capture_io(fn ->
        Render.card(
          card([
            %{
              "id" => 9,
              "title" => "There",
              "board_id" => 5,
              "board" => "plat",
              "completed" => true
            }
          ])
        )
      end)

    assert out =~ "plat #9 There (done)"
  end

  test "a hidden blocker shows only what the server sent" do
    out =
      capture_io(fn ->
        Render.card(
          card([
            %{
              "id" => 11,
              "title" => "A card you can't see",
              "board_id" => nil,
              "board" => nil,
              "hidden" => true,
              "completed" => false
            }
          ])
        )
      end)

    assert out =~ "#11 A card you can't see (open)"
  end
end
