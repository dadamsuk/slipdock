defmodule SlipdockCLI.JobsTest do
  @moduledoc """
  Parked jobs from the CLI (#1115): `jobs` shows a parked job as waiting on
  a person, `finish-job --status waiting` asks and parks in one request,
  with `--on` read as the person, and `claim-job` prints the answered
  question and the handoff a job carries on from.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias SlipdockCLI.{FakeServer, Runners}

  setup do
    home = Path.join(System.tmp_dir!(), "slipdock-jobs-#{System.unique_integer([:positive])}")
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

  defp parse(argv) do
    {o, args, []} =
      OptionParser.parse(SlipdockCLI.wait_on(argv), strict: SlipdockCLI.switches())

    {o, args}
  end

  test "jobs shows a parked job as waiting on a person, and passes --status parked" do
    serve([
      {200,
       ~s({"jobs":[{"id":9,"status":"parked","card_id":4,"card":"Deploy","pool":"loop","kind":"claude","runner":"box","finished_at":"2026-10-19T02:00:00Z"},{"id":8,"status":"done","card_id":3,"card":"Fix","pool":"loop","kind":"claude"}]})}
    ])

    out = capture_io(fn -> Runners.run("jobs", ["b"], status: "parked") end)

    assert_received {:request, "GET", "/api/boards/b/jobs" <> query, _}
    assert query =~ "status=parked"
    assert out =~ "parked (waiting on a person)"
    assert out =~ ~r/8\s+done/
  end

  test "job shows parked too" do
    serve([
      {200,
       ~s({"job":{"id":9,"status":"parked","card_id":4,"pool":"loop","kind":"claude","queued_at":"2026-10-19T02:00:00Z","prompt":"p"}})}
    ])

    out = capture_io(fn -> Runners.run("job", ["9"], []) end)
    assert out =~ "job #9  parked (waiting on a person)  card #4"
  end

  test "finish-job --status waiting asks and parks in one request" do
    {o, ["finish-job", "9"]} =
      parse(
        ["finish-job", "9", "--status", "waiting", "--needs", "Which region?"] ++
          ~w(--choice eu --choice us --on dana@example.com --summary Asked)
      )

    assert o[:wait_on] == "dana@example.com"

    serve([
      {200,
       ~s({"job":{"id":9,"status":"parked","card_id":4},"wait":{"needs":"Which region?","on":{"name":"Dana"},"choices":["eu","us"]}})}
    ])

    out = capture_io(fn -> Runners.run("finish-job", ["9"], o) end)

    assert_received {:request, "POST", "/api/jobs/9/finish", body}

    assert JSON.decode!(body) == %{
             "outcome" => "waiting",
             "summary" => "Asked",
             "wait" => %{
               "needs" => "Which region?",
               "on" => "dana@example.com",
               "choices" => ["eu", "us"]
             }
           }

    assert out =~ "job #9 parked: #4 waits on Dana: Which region?"
  end

  test "finish-job without --status waiting sends no wait" do
    serve([{200, ~s({"job":{"id":9,"status":"done","card_id":4}})}])

    out = capture_io(fn -> Runners.run("finish-job", ["9"], status: "done") end)

    assert_received {:request, "POST", "/api/jobs/9/finish", body}
    assert JSON.decode!(body) == %{"outcome" => "done"}
    assert out =~ "job #9 done"
  end

  test "claim-job prints the answered question and the handoff a job carries on from" do
    serve([
      {200,
       ~s({"job":{"id":12,"kind":"claude","card_id":4,"card_url":"https://x/c/4","prompt":"Question on card #4: Which region?"},"lease_seconds":1200,"wait":{"needs":"Which region?","choice_text":"eu","answer":"soon"},"handoff":{"next_step":"Pick a region"}})}
    ])

    out = capture_io(fn -> Runners.run("claim-job", ["b"], pool: "loop") end)

    assert out =~ "claimed job #12"
    assert out =~ "answered: eu — soon"
    assert out =~ "left off: Pick a region"
    assert out =~ "Question on card #4: Which region?"
  end

  test "claim-job without a wait or handoff prints neither" do
    serve([
      {200,
       ~s({"job":{"id":12,"kind":"claude","card_id":4,"card_url":"u","prompt":"Work"},"lease_seconds":1200,"wait":null,"handoff":null})}
    ])

    out = capture_io(fn -> Runners.run("claim-job", ["b"], pool: "loop") end)
    refute out =~ "answered:"
    refute out =~ "left off:"
  end
end
