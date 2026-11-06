defmodule SlipdockCLI.JobLogTest do
  @moduledoc """
  Watching a job from the CLI (#1871): `slipdock job <id> --follow` prints
  its live log as it arrives and returns once the job has ended (exit 0);
  `slipdock job-log <id>` prints what is there so far.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias SlipdockCLI.{FakeServer, HTTP, Runners}

  setup do
    home = Path.join(System.tmp_dir!(), "slipdock-joblog-#{System.unique_integer([:positive])}")
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

  defp serve(responses), do: System.put_env("SLIPDOCK_URL", FakeServer.start(responses))

  defp page(status, open, next, lines) do
    entries = Enum.map(lines, &%{"id" => "x", "kind" => "message", "text" => &1, "line" => &1})

    {200,
     HTTP.encode(%{
       "job" => %{"id" => 9, "status" => status, "open" => open},
       "next" => next,
       "capped" => false,
       "entries" => entries
     })}
  end

  test "--follow is a switch, and job --follow reads the log until the job ends" do
    {o, ["job", "9"], []} =
      OptionParser.parse(["job", "9", "--follow", "--interval", "0"],
        strict: SlipdockCLI.switches()
      )

    assert o[:follow] == true and o[:interval] == 0

    serve([
      page("running", true, 2, ["12:00:01  💬 one", "12:00:02  ▶ Bash: ls"]),
      page("running", true, 2, []),
      page("running", true, 3, ["12:01:00     ↳ done"]),
      page("done", false, 3, [])
    ])

    out =
      capture_io(fn ->
        send(self(), {:stderr, capture_io(:stderr, fn -> Runners.run("job", ["9"], o) end)})
      end)

    assert_received {:stderr, err}

    assert out == "12:00:01  💬 one\n12:00:02  ▶ Bash: ls\n12:01:00     ↳ done\n"
    assert err =~ "job #9 done"

    # Each read starts where the last ended.
    froms =
      for _ <- 1..4 do
        assert_received {:request, "GET", "/api/jobs/9/log?" <> query, _}
        URI.decode_query(query)["from"]
      end

    assert froms == ~w(0 2 2 3)
  end

  test "job-log prints what is there and stops, even while the job runs" do
    serve([page("running", true, 1, ["12:00:01  💬 one"])])
    assert capture_io(fn -> Runners.run("job-log", ["9"], []) end) == "12:00:01  💬 one\n"
    assert_received {:request, "GET", "/api/jobs/9/log?from=0", _}
  end

  test "--json prints one entry per line" do
    serve([page("done", false, 1, ["12:00:01  💬 one"])])
    out = capture_io(fn -> Runners.run("job-log", ["9"], json: true, follow: true) end)
    assert [line] = String.split(out, "\n", trim: true)
    assert line =~ ~s("kind":"message")
  end

  test "job without --follow is the job itself, as before" do
    serve([
      {200,
       ~s({"job":{"id":9,"status":"running","card_id":4,"pool":"loop","kind":"claude","prompt":"p"}})}
    ])

    out = capture_io(fn -> Runners.run("job", ["9"], []) end)
    assert out =~ "job #9  running"
    assert_received {:request, "GET", "/api/jobs/9", _}
  end
end
