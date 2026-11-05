defmodule SlipdockCLI.HealthTest do
  @moduledoc "`slipdock health`: what it sends, and what it shows (W-2310)."
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias SlipdockCLI.{FakeServer, Health}

  setup do
    home = Path.join(System.tmp_dir!(), "slipdock-health-#{System.unique_integer([:positive])}")
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

    :ok
  end

  defp serve(responses), do: System.put_env("SLIPDOCK_URL", FakeServer.start(responses))

  @flagged %{
    "id" => 7,
    "detector" => "no_runner",
    "status" => "flagged",
    "summary" => "Job #12 has waited 20 minutes with no runner online in pool dev",
    "card" => %{"id" => 1759, "title" => "Health monitor"},
    "attempts" => 0
  }

  @fixed %{
    "id" => 6,
    "detector" => "idle_feed",
    "status" => "fixed",
    "summary" => "The feed was idle",
    "card" => nil,
    "attempts" => 1
  }

  test "health <board> lists what is stuck, then lately, then the last run" do
    body = %{
      "incidents" => [@flagged],
      "recent" => [@fixed],
      "last_run" => "2026-11-05T09:00:00Z"
    }

    serve([{200, JSON.encode!(body)}])
    out = capture_io(fn -> Health.run("health", ["ops"], []) end)

    assert_received {:request, "GET", "/api/boards/ops/health", _}
    assert out =~ "Stuck now (1)"
    assert out =~ "#7 [flagged] no_runner #1759: Job #12 has waited 20 minutes"
    assert out =~ "Lately"
    assert out =~ "#6 [fixed] idle_feed: The feed was idle (1 tried)"
    assert out =~ "Monitor last ran 2026-11-05T09:00."
  end

  test "--run posts a run; nothing stuck says so" do
    serve([{200, JSON.encode!(%{"incidents" => [], "recent" => [], "last_run" => nil})}])
    out = capture_io(fn -> Health.run("health", ["ops"], run: true) end)
    assert_received {:request, "POST", "/api/boards/ops/health", _}
    assert out =~ "Nothing stuck."
    assert out =~ "The monitor hasn't run yet."
  end

  test "settings shows the detectors, and key=value changes one" do
    detectors = %{
      "detectors" => [
        %{
          "key" => "no_runner",
          "enabled" => true,
          "settings" => %{"enabled" => true, "minutes" => 15, "max_attempts" => 2}
        }
      ]
    }

    serve([{200, JSON.encode!(detectors)}, {200, JSON.encode!(detectors)}])
    out = capture_io(fn -> Health.run("health", ["settings", "ops"], []) end)
    assert out =~ ~r/on\s+no_runner\s+max_attempts=2 minutes=15/

    capture_io(fn -> Health.run("health", ["settings", "ops", "no_runner", "minutes=30"], []) end)
    assert_received {:request, "PATCH", "/api/boards/ops/health/settings", body}
    assert JSON.decode!(body) == %{"detector" => "no_runner", "minutes" => "30"}
  end

  test "the arguments" do
    assert Health.settings_args([]) == {:ok, nil}
    assert {:error, "say what to change" <> _} = Health.settings_args(["no_runner"])
    assert {:error, "settings are key=value" <> _} = Health.settings_args(["no_runner", "x"])
  end
end
