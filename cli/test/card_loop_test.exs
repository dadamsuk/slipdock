defmodule SlipdockCLI.CardLoopTest do
  @moduledoc """
  `slipdock card` and the board listing on a card a runner loop holds
  (#2027): the loop beside the assignees, never one of them.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias SlipdockCLI.Render

  @loop %{"runner" => "Mac Studio", "kind" => "verify", "job_id" => 41}

  defp card(attrs) do
    Map.merge(
      %{
        "id" => 12,
        "title" => "Ship",
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

  test "slipdock card: a Loop line under an empty Assignee" do
    out = capture_io(fn -> Render.card(card(%{"loop" => @loop})) end)
    assert out =~ ~r/Assignee:\s+-\n/
    assert out =~ ~r/Loop:\s+Mac Studio · verify \(job #41\)/
  end

  test "slipdock card: a person and the loop, both" do
    person = %{"name" => "Dana", "email" => "dana@example.com"}
    out = capture_io(fn -> Render.card(card(%{"loop" => @loop, "assignees" => [person]})) end)
    assert out =~ "Dana <dana@example.com>"
    assert out =~ "Mac Studio · verify"
  end

  test "no loop, no Loop line" do
    out = capture_io(fn -> Render.card(card(%{})) end)
    refute out =~ "Loop:"
    refute Render.card_line(card(%{}), false) =~ "⟳"
  end

  test "the listing marks the loop" do
    assert Render.card_line(card(%{"loop" => @loop}), false) =~ "⟳Mac Studio·verify"

    nameless = %{@loop | "runner" => nil, "kind" => "build"}
    assert Render.card_line(card(%{"loop" => nameless}), false) =~ "⟳a runner·build"
  end
end
