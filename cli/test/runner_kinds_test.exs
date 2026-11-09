defmodule SlipdockCLI.RunnerKindsTest do
  @moduledoc "`slipdock runner` shows the kinds a runner said it takes (#1656)."
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias SlipdockCLI.Render

  defp runner(kinds) do
    %{
      "id" => 4,
      "name" => "laptop",
      "pool" => "dev",
      "session" => false,
      "settings" => %{},
      "created_at" => "2026-11-03T10:00:00Z",
      "last_seen_at" => nil,
      "kinds" => kinds,
      "current_job" => nil,
      "stats" => %{},
      "jobs" => [],
      "rules" => []
    }
  end

  test "lists the kinds it takes" do
    out = capture_io(fn -> Render.runner(runner(["claude", "merge"])) end)
    assert out =~ "takes:     claude, merge"
  end

  test "an older runner that never said is shown as taking no merge jobs" do
    out = capture_io(fn -> Render.runner(runner(nil)) end)
    assert out =~ "not said (an older runner: no merge jobs)"
  end

  # The SCRIPT column went with the scripts (#2582); what a runner lacks stays.
  test "the list and the runner say what it lacks, and nothing of a script (#1658, #2582)" do
    out =
      capture_io(fn ->
        Render.runners([
          Map.merge(runner(["claude"]), %{"missing_kinds" => ["merge"]}),
          Map.merge(runner(["merge"]), %{"id" => 5, "missing_kinds" => []}),
          Map.merge(runner(nil), %{"id" => 6, "script" => "out_of_date"})
        ])
      end)

    [header | rows] = String.split(out, "\n", trim: true)
    assert header =~ "LACKS"
    refute header =~ "SCRIPT"
    assert Enum.at(rows, 0) =~ "merge"
    refute out =~ "out of date"
    refute out =~ "old (can't say)"

    one = Map.merge(runner(["claude"]), %{"missing_kinds" => ["merge"], "machine_id" => 3})
    shown = capture_io(fn -> Render.runner(one) end)
    assert shown =~ "lacks:     merge"
    assert shown =~ "(a machine's runner)"
    refute shown =~ "script:"
  end
end
