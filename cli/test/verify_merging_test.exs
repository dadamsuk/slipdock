defmodule SlipdockCLI.VerifyMergingTest do
  @moduledoc "`slipdock card` on a card being merged, and once merged (#1657)."
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias SlipdockCLI.Render

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

  test "a merging card says who accepted it and how to mark it merged by hand" do
    c = card(%{"verify_state" => "merging", "verify_by" => %{"kind" => "human"}})
    out = capture_io(fn -> Render.card(c) end)
    assert out =~ "merging — accepted by a person"
    assert out =~ "slipdock verify 12 merged"
    assert Render.card_line(c, false) =~ "⇄merging"
  end

  test "a merged card shows its merge commit" do
    c =
      card(%{
        "verify_state" => "accepted",
        "verify_by" => %{"kind" => "human"},
        "merge_sha" => "abc1234"
      })

    assert capture_io(fn -> Render.card(c) end) =~ "merged as abc1234"
  end
end
