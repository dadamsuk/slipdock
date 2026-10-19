defmodule SlipdockCLI.PauseTest do
  @moduledoc """
  `slipdock pause <board> [--pool P] --reason "…"` and `slipdock resume
  <board> [--pool P]` (#1116): what they send and print, the pause shown
  first by `board`, `cards` and an empty `claim-job`, and `set-board
  --automation-wip`. Refusals end in `System.halt/1`, so they are covered
  as the values the command halts on; the server's side is in
  `test/slipdock_web/pause_api_test.exs`.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias SlipdockCLI.{Boards, FakeServer, HTTP, Runners}

  @vars ~w(HOME CLAUDECODE SLIPDOCK_JOB_ID SLIPDOCK_URL SLIPDOCK_TOKEN KANBAN_TOKEN)

  setup do
    home = Path.join(System.tmp_dir!(), "slipdock-pause-#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    saved = Map.new(@vars, &{&1, System.get_env(&1)})
    Enum.each(@vars, &System.delete_env/1)
    System.put_env("HOME", home)
    System.put_env("SLIPDOCK_TOKEN", "test-token")

    on_exit(fn ->
      Enum.each(saved, fn
        {k, nil} -> System.delete_env(k)
        {k, v} -> System.put_env(k, v)
      end)

      File.rm_rf!(home)
    end)
  end

  @pause %{
    "id" => 4,
    "board_id" => 3,
    "pool" => "dev",
    "scope" => "pool dev",
    "reason" => "bad deploy",
    "by" => "David",
    "line" => "paused by David: bad deploy",
    "paused_at" => "2026-10-19T03:00:00Z",
    "resumed_at" => nil
  }

  defp serve(responses), do: System.put_env("SLIPDOCK_URL", FakeServer.start(responses))

  test "the switches parse" do
    {opts, ["pause", "ops"], []} =
      OptionParser.parse(["pause", "ops", "--pool", "dev", "--reason", "bad deploy"],
        strict: SlipdockCLI.switches()
      )

    assert opts[:pool] == "dev"
    assert opts[:reason] == "bad deploy"

    {opts, _, []} =
      OptionParser.parse(["set-board", "ops", "--automation-wip"], strict: SlipdockCLI.switches())

    assert opts[:automation_wip] == true
  end

  test "pause sends the pool and reason, and prints the line" do
    serve([{201, JSON.encode!(%{"pause" => @pause})}])

    out = capture_io(fn -> Runners.run("pause", ["ops"], pool: "dev", reason: "bad deploy") end)

    assert_received {:request, "POST", "/api/boards/ops/pause", sent}
    assert JSON.decode!(sent) == %{"pool" => "dev", "reason" => "bad deploy"}
    assert out == "pool dev paused by David: bad deploy\n"
  end

  test "without --pool it pauses the whole tree" do
    tree = %{@pause | "pool" => nil, "scope" => "the whole tree"}
    serve([{201, JSON.encode!(%{"pause" => tree})}])

    out = capture_io(fn -> Runners.run("pause", ["ops"], reason: "freeze") end)

    assert_received {:request, "POST", "/api/boards/ops/pause", sent}
    assert JSON.decode!(sent) == %{"reason" => "freeze"}
    assert out =~ "the whole tree paused by"
  end

  test "resume names exactly the scope: the pool, or none for the tree" do
    resumed = %{@pause | "resumed_at" => "2026-10-19T04:00:00Z"}

    serve([
      {200, JSON.encode!(%{"pause" => resumed})},
      {200, JSON.encode!(%{"pause" => resumed})}
    ])

    assert capture_io(fn -> Runners.run("resume", ["ops"], pool: "dev") end) ==
             "resumed pool dev\n"

    assert_received {:request, "DELETE", "/api/boards/ops/pause?pool=dev", _}

    capture_io(fn -> Runners.run("resume", ["ops"], []) end)
    assert_received {:request, "DELETE", "/api/boards/ops/pause", _}
  end

  test "under an agent, resume says so, and the server's refusal is what it halts on" do
    System.put_env("CLAUDECODE", "1")
    refusal = %{"error" => "forbidden: only a person can resume: on the board's Runners panel"}
    serve([{403, JSON.encode!(refusal)}])

    assert {:error, 403, %{"error" => "forbidden: only a person can resume" <> _}} =
             HTTP.delete("/boards/ops/pause", pool: "dev")

    assert_received {:headers, "DELETE", "/api/boards/ops/pause?pool=dev", headers}
    assert headers["x-slipdock-agent"] == "1"
  end

  test "a pause by someone who doesn't own the board is refused" do
    serve([{403, ~s({"error":"forbidden: you don't own this board"})}])

    assert {:error, 403, %{"error" => "forbidden: you don't own" <> _}} =
             HTTP.post("/boards/ops/pause", %{"reason" => "mine now"})
  end

  test "board and cards print the pause first" do
    serve([
      {200,
       JSON.encode!(%{
         "board" => %{"id" => 3, "name" => "Ops", "columns" => [], "tags" => []},
         "paused" => [@pause]
       })},
      {200, JSON.encode!(%{"cards" => [], "paused" => [@pause]})}
    ])

    board = capture_io(fn -> Boards.run("board", ["ops"], []) end)
    assert board =~ ~r/^PAUSED pool dev: paused by David: bad deploy\n/

    cards = capture_io(fn -> Boards.run("cards", ["ops"], []) end)
    assert cards =~ ~r/^PAUSED pool dev: paused by David: bad deploy\n/
  end

  test "nothing paused, nothing printed for it" do
    serve([{200, JSON.encode!(%{"cards" => []})}])
    refute capture_io(fn -> Boards.run("cards", ["ops"], []) end) =~ "PAUSED"
  end

  test "an empty claim says why work is held" do
    serve([
      {200,
       JSON.encode!(%{"job" => nil, "held" => "paused by David: bad deploy", "paused" => @pause})},
      {200,
       JSON.encode!(%{
         "job" => nil,
         "held" => "WIP full: In Progress 3/3",
         "waiting" => %{"job" => 9, "card_id" => 12, "reason" => "WIP full: In Progress 3/3"}
       })}
    ])

    assert capture_io(fn -> Runners.run("claim-job", ["ops"], pool: "dev") end) ==
             "nothing queued to take: paused by David: bad deploy\n"

    assert capture_io(fn -> Runners.run("claim-job", ["ops"], pool: "dev") end) ==
             "nothing queued to take: job #9 waits while WIP full: In Progress 3/3\n"
  end

  test "set-board --automation-wip is sent to the board" do
    serve([{200, ~s({"board":{"id":3,"name":"Ops"}})}])
    capture_io(fn -> Boards.run("set-board", ["ops"], automation_wip: true) end)
    assert_received {:request, "PATCH", "/api/boards/ops", sent}
    assert JSON.decode!(sent) == %{"automation_wip" => true}
  end
end
