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
end
