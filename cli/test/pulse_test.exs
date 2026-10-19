defmodule SlipdockCLI.PulseTest do
  @moduledoc """
  `slipdock pulse <board>` (#1113): asks the server for the board's pulse,
  prints the numbers it was given, and with `--json` hands them on untouched,
  so the CLI says what REST and MCP say. `set-board --show-pulse` turns the
  web strip on.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias SlipdockCLI.{Boards, FakeServer}

  setup do
    home = Path.join(System.tmp_dir!(), "slipdock-pulse-#{System.unique_integer([:positive])}")
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

  # What the server answers (`SlipdockWeb.API.BoardController.pulse/2`).
  @pulse %{
    "in_progress" => 6,
    "waiting" => 2,
    "oldest_wait_at" => nil,
    "done_7d" => 23,
    "done_today" => 3,
    "time_to_done" => %{"p50" => 86_400, "p85" => 3 * 86_400, "cards" => 23, "lead_time" => 4},
    "moves_24h" => %{"forward" => 9, "back" => 2, "total" => 12},
    "lists" => [
      %{
        "id" => 1,
        "name" => "To Do",
        "category" => "todo",
        "in_7d" => 8,
        "out_7d" => 7,
        "usual_stay" => 7200
      },
      %{
        "id" => 2,
        "name" => "Done",
        "category" => "done",
        "in_7d" => 5,
        "out_7d" => 0,
        "usual_stay" => nil
      }
    ],
    "at" => "2026-10-19T15:00:00Z"
  }

  defp serve(body), do: System.put_env("SLIPDOCK_URL", FakeServer.start([{200, body}]))

  test "prints the board's numbers" do
    serve(JSON.encode!(%{"board" => %{"id" => 3, "code" => "ops"}, "pulse" => @pulse}))

    out = capture_io(fn -> Boards.run("pulse", ["ops"], []) end)

    assert_received {:request, "GET", "/api/boards/ops/pulse", _}
    assert out =~ "6 in progress · 2 waiting"
    assert out =~ "23 done in 7 days, 3 today"
    assert out =~ "time to done: P50 1d · P85 3d over 23 cards (4 from when made)"
    assert out =~ "moves in 24h: 9 forward · 2 back · 12 in all"
    assert out =~ "To Do  in 8 · out 7  usually 2h"
    assert out =~ ~r/Done  in 5 · out 0\n/
  end

  test "an empty board prints zeros and dashes, not a crash" do
    empty = %{
      @pulse
      | "in_progress" => 0,
        "waiting" => 0,
        "done_7d" => 0,
        "done_today" => 0,
        "time_to_done" => %{"p50" => nil, "p85" => nil, "cards" => 0, "lead_time" => 0},
        "moves_24h" => %{"forward" => 0, "back" => 0, "total" => 0},
        "lists" => []
    }

    serve(JSON.encode!(%{"pulse" => empty}))
    out = capture_io(fn -> Boards.run("pulse", ["quiet"], []) end)

    assert out =~ "0 in progress · 0 waiting"
    assert out =~ "time to done: P50 - · P85 - over 0 cards\n"
  end

  test "--json hands the server's numbers on as they came" do
    body = %{"board" => %{"id" => 3, "code" => "ops"}, "pulse" => @pulse}
    serve(JSON.encode!(body))

    out = capture_io(fn -> Boards.run("pulse", ["ops"], json: true) end)
    assert JSON.decode!(out) == body
  end

  test "--show-pulse parses and is sent to the board" do
    {opts, ["set-board", "ops"], []} =
      OptionParser.parse(["set-board", "ops", "--show-pulse"], strict: SlipdockCLI.switches())

    assert opts[:show_pulse] == true

    serve(~s({"board":{"id":3,"name":"Ops"}}))
    capture_io(fn -> Boards.run("set-board", ["ops"], show_pulse: true) end)
    assert_received {:request, "PATCH", "/api/boards/ops", sent}
    assert JSON.decode!(sent) == %{"show_pulse" => true}
  end
end
