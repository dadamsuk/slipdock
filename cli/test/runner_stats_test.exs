defmodule SlipdockCLI.RunnerStatsTest do
  @moduledoc "`slipdock runner-stats <board>` (#1187): what it asks for and how it prints."
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias SlipdockCLI.{FakeServer, Runners}

  setup do
    home = Path.join(System.tmp_dir!(), "slipdock-rstats-#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    saved = Map.new(~w(HOME SLIPDOCK_URL SLIPDOCK_TOKEN KANBAN_TOKEN), &{&1, System.get_env(&1)})
    System.put_env("HOME", home)
    System.put_env("SLIPDOCK_TOKEN", "test-token")
    Enum.each(~w(SLIPDOCK_URL KANBAN_TOKEN), &System.delete_env/1)

    on_exit(fn ->
      Enum.each(saved, fn
        {k, nil} -> System.delete_env(k)
        {k, v} -> System.put_env(k, v)
      end)

      File.rm_rf!(home)
    end)
  end

  defp serve(stats),
    do:
      System.put_env(
        "SLIPDOCK_URL",
        FakeServer.start([{200, JSON.encode!(%{"runner_stats" => stats})}])
      )

  test "prints each runner's numbers and the recent jobs, passing --days on" do
    serve(%{
      "days" => 7,
      "runners" => [
        %{
          "name" => "dev-box",
          "pool" => "dev",
          "status" => "running",
          "current" => %{"job_id" => 41, "card_id" => 1185, "elapsed" => 600},
          "outcomes" => %{"done" => 8, "parked" => 1, "failed" => 1, "running" => 1},
          "success_rate" => 0.8,
          "duration" => %{"p50" => 1800, "p85" => 3600},
          "queue_wait" => %{"p50" => 120, "p85" => 300},
          "waits" => %{"opened" => 2, "open" => 1, "answer" => %{"p50" => 7200}},
          "reopened" => %{"count" => 1, "card_ids" => [9]}
        }
      ],
      "recent_jobs" => [
        %{
          "job_id" => 41,
          "card_id" => 1185,
          "title" => "Visualise",
          "outcome" => "parked",
          "reason" => "Which colour?",
          "duration" => 600
        }
      ]
    })

    out = capture_io(fn -> Runners.run("runner-stats", ["ship"], days: 7) end)
    assert_received {:request, "GET", path, _}
    assert path =~ "/api/boards/ship/runner_stats?days=7"

    assert out =~ "dev-box (dev) · running · job #41 card #1185 for 10m"
    assert out =~ "8 done · 1 parked · 1 failed · 1 running · 80% succeeded"
    assert out =~ "job P50 30m · queue wait P50 2m"
    assert out =~ "waits on people 2 (1 open, answered in 2h) · reopened 1"
    assert out =~ "#41  parked: Which colour?  10m  card #1185 Visualise"
  end

  test "no runners says so" do
    serve(%{"days" => 30, "runners" => [], "recent_jobs" => []})
    out = capture_io(fn -> Runners.run("runner-stats", ["ship"], []) end)
    assert out =~ "no runners take work from this board"
  end
end
