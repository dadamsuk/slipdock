defmodule SlipdockCLI.LedgerTest do
  @moduledoc "`slipdock ledger`: what it sends and how a line reads (#1948)."
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias SlipdockCLI.{FakeServer, Ledger}

  setup do
    home = Path.join(System.tmp_dir!(), "slipdock-ledger-#{System.unique_integer([:positive])}")
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

  @line %{
    "card" => %{"id" => 1948, "title" => "The ledger", "board_id" => 168},
    "events" => ["completed", "accepted", "merged"],
    "accepted_by" => %{"kind" => "agent", "name" => "runner Mac"},
    "audit" => %{"verdict" => "agrees"},
    "evidence" => "Built it; CI green",
    "should_broken" => [%{"id" => "UX-4"}, %{"id" => "ARCH-6"}],
    "pr" => "https://github.com/example/repo/pull/9",
    "deploys" => [%{"environment" => "production", "sha" => "abc1234def"}],
    "lead_time" => %{
      "seconds" => 7200,
      "phases" => %{"build" => 3600, "ci" => 1800, "verify" => 600, "merge" => 60}
    },
    "subcards" => nil
  }

  @ledger %{
    "since" => "2026-11-06T07:00:00Z",
    "timezone" => "Europe/London",
    "count" => 2,
    "days" => [
      %{"date" => "2026-11-07", "items" => [@line]},
      %{
        "date" => "2026-11-06",
        "items" => [
          %{
            "card" => %{"id" => 1947, "title" => "Epic"},
            "events" => ["completed"],
            "accepted_by" => nil,
            "subcards" => %{"total" => 2, "done" => 2, "on_ledger" => 1},
            "lead_time" => %{"seconds" => 0, "phases" => %{}}
          }
        ]
      }
    ]
  }

  test "ledger <board> asks for the default window and prints a line per card, by day" do
    serve([{200, JSON.encode!(@ledger)}])
    out = capture_io(fn -> Ledger.run("ledger", ["slipdock"], []) end)

    assert_received {:request, "GET", path, _}
    assert path =~ "/api/boards/slipdock/ledger"
    refute path =~ "since="

    assert out =~ "2 shipped since 2026-11-06T07:00:00Z (Europe/London)"
    assert out =~ "## 2026-11-07"
    assert out =~ "#1948 The ledger  [completed, accepted, merged]"
    assert out =~ "accepted by runner Mac; audit agrees"
    assert out =~ "evidence: Built it; CI green"
    assert out =~ "should missed: UX-4, ARCH-6"
    assert out =~ "pr https://github.com/example/repo/pull/9; deployed to production abc1234"
    assert out =~ "lead time 2h0m: build 1h0m, ci 30m, verify 10m"
    refute out =~ "merge 1m"
    assert out =~ "## 2026-11-06"
    assert out =~ "#1947 Epic  [completed]  2/2 subcards, 1 here"
    assert out =~ "not verified"
    # The newer day comes first.
    assert :binary.match(out, "2026-11-07") < :binary.match(out, "## 2026-11-06")
  end

  test "--since goes in the query as given, through the command line" do
    serve([{200, JSON.encode!(%{@ledger | "days" => [], "count" => 0})}])
    out = capture_io(fn -> SlipdockCLI.main(["ledger", "slipdock", "--since", "2026-11-01"]) end)

    assert_received {:request, "GET", path, _}
    assert path =~ "since=2026-11-01"
    assert out =~ "Nothing shipped since 2026-11-06T07:00:00Z."
  end

  test "--since takes days too" do
    serve([{200, JSON.encode!(%{@ledger | "days" => [], "count" => 0})}])
    capture_io(fn -> SlipdockCLI.main(["ledger", "slipdock", "--since", "7"]) end)
    assert_received {:request, "GET", path, _}
    assert path =~ "since=7"
  end

  test "durations read short" do
    assert Ledger.duration(5) == "5s"
    assert Ledger.duration(125) == "2m"
    assert Ledger.duration(90_000) == "1d1h"
  end

  test "--help lists the command" do
    help = capture_io(fn -> SlipdockCLI.main(["--help"]) end)
    assert help =~ "ledger <board> [--since S]"
  end
end
