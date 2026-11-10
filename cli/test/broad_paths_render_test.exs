defmodule SlipdockCLI.BroadPathsRenderTest do
  @moduledoc """
  `card` marking a broad lane glob (#2698): the globs the server lists in
  `paths_broad` are marked `broad`, with its reason under them, and the
  overlap line says whose glob is broad.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias SlipdockCLI.Render

  defp card(extra) do
    Map.merge(
      %{
        "id" => 12,
        "title" => "Pathed",
        "board_id" => 3,
        "flags" => [],
        "tags" => [],
        "assignees" => [],
        "blocked_by" => [],
        "blocks" => [],
        "checklist" => %{"done" => 0, "total" => 0, "items" => []},
        "comments" => [],
        "attachments" => [],
        "urls" => [],
        "links" => [],
        "paths" => ["lib/**", "lib/slipdock/a.ex", "docs/manual.md"],
        "paths_shared" => ["docs/manual.md"]
      },
      extra
    )
  end

  test "a broad glob is marked, with the server's reason; the others aren't" do
    out =
      capture_io(fn ->
        Render.card(
          card(%{
            "paths_broad" => ["lib/**"],
            "paths_broad_reason" => "it overlaps most cards; name the files"
          })
        )
      end)

    assert out =~ "lib/**  broad"
    assert out =~ "broad: it overlaps most cards; name the files"
    refute out =~ "lib/slipdock/a.ex  broad"
    assert out =~ "docs/manual.md  shared"
  end

  test "no paths_broad marks nothing" do
    out = capture_io(fn -> Render.card(card(%{})) end)
    refute out =~ "broad"
  end

  test "the overlap line names whose glob is broad" do
    overlap = %{"card" => 7, "title" => "Wide", "mode" => "advise"}

    out =
      capture_io(fn ->
        Render.card(
          card(%{
            "lane_overlap" =>
              Map.merge(overlap, %{"broad" => "other", "broad_paths" => ["lib/**"]})
          })
        )
      end)

    assert out =~ "an agent may start (its broad lib/**)"

    out = capture_io(fn -> Render.card(card(%{"lane_overlap" => overlap})) end)
    assert out =~ "an agent may start\n"
  end
end
