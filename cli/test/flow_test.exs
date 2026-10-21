defmodule SlipdockCLI.FlowTest do
  @moduledoc """
  `slipdock flow <board>` (#1186): asks for the board's flow day by day,
  passes `--days` on, prints a row per day, and the weeks at 90 days.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias SlipdockCLI.{Boards, FakeServer}

  setup do
    home = Path.join(System.tmp_dir!(), "slipdock-flow-#{System.unique_integer([:positive])}")
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

  defp flow(days) do
    %{
      "days" => days,
      "timezone" => "Europe/London",
      "since" => "2026-10-13",
      "until" => "2026-10-19",
      "series" => [
        %{
          "date" => "2026-10-19",
          "backlog" => 12,
          "ready" => 3,
          "doing" => 2,
          "done" => 9,
          "completed" => 4,
          "added" => 1,
          "open" => 17
        }
      ],
      "weeks" => [%{"week" => "2026-W43", "start" => "2026-10-19", "completed" => 4}],
      "finished" => [],
      "cycle" => %{"p50" => 3600, "p85" => 2 * 86_400, "cards" => 9}
    }
  end

  defp serve(body),
    do:
      System.put_env(
        "SLIPDOCK_URL",
        FakeServer.start([{200, JSON.encode!(%{"board" => %{"id" => 3}, "flow" => body})}])
      )

  test "prints a row per day and the cycle time, passing --days on" do
    serve(flow(7))
    out = capture_io(fn -> Boards.run("flow", ["ship"], days: 7) end)

    assert_received {:request, "GET", path, _}
    assert path =~ "/api/boards/ship/flow?days=7"

    assert out =~ "last 7 days (2026-10-13 to 2026-10-19, Europe/London)"
    assert out =~ ~r/2026-10-19\s+12\s+3\s+2\s+9\s+4\s+1\s+17/
    assert out =~ "cycle time: P50 1h · P85 2d over 9 cards"
    refute out =~ "completed by week"
  end

  test "without --days asks for the server's default; at 90 days prints the weeks" do
    serve(flow(90))
    out = capture_io(fn -> Boards.run("flow", ["ship"], []) end)

    assert_received {:request, "GET", path, _}
    assert String.ends_with?(path, "/api/boards/ship/flow")
    assert out =~ "completed by week:"
    assert out =~ "2026-W43  4"
  end

  test "--json hands the answer on untouched" do
    serve(flow(30))
    out = capture_io(fn -> Boards.run("flow", ["ship"], json: true) end)
    assert JSON.decode!(out)["flow"]["cycle"]["cards"] == 9
  end
end
