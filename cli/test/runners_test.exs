defmodule SlipdockCLI.RunnersTest do
  @moduledoc "`slipdock runner`, `jobs`, `job` and `cancel-job`: what each asks the server, and what it prints."
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias SlipdockCLI.{FakeServer, Runners}

  setup do
    home = Path.join(System.tmp_dir!(), "slipdock-runners-#{System.unique_integer([:positive])}")
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

  test "runner new posts the name and pool and prints the token once" do
    serve([
      {201, ~s({"runner":{"id":4,"name":"laptop","pool":"dev"},"token":"sdr_secret"})}
    ])

    out = capture_io(fn -> Runners.run("runner", ["new", "b", "laptop"], pool: "dev") end)
    assert_received {:request, "POST", "/api/boards/b/runners", body}
    assert JSON.decode!(body) == %{"name" => "laptop", "pool" => "dev"}
    assert out =~ "made runner #4 laptop for pool dev"
    assert out =~ "sdr_secret"
  end

  test "runner ls and rm" do
    serve([
      {200,
       ~s({"runners":[{"id":4,"name":"laptop","pool":"dev","last_seen_at":null,"current_job_id":9}]})},
      {200, ~s({"ok":true})}
    ])

    out = capture_io(fn -> Runners.run("runners", ["b"], []) end)
    assert_received {:request, "GET", "/api/boards/b/runners", _}
    assert out =~ "laptop"
    assert out =~ "never"
    assert out =~ "job #9"

    out = capture_io(fn -> Runners.run("runner", ["rm", "b", "laptop"], []) end)
    assert_received {:request, "DELETE", "/api/boards/b/runners/laptop", _}
    assert out =~ "revoked runner laptop"
  end

  test "jobs for a board passes --status; --card asks for one card's" do
    job =
      ~s({"id":7,"status":"running","cancel_requested":true,"card_id":12,"card":"Fix","pool":"dev","kind":"claude","runner":"laptop","queued_at":"2026-10-08T10:00:00Z"})

    serve([{200, ~s({"jobs":[#{job}]})}, {200, ~s({"jobs":[]})}])

    out = capture_io(fn -> Runners.run("jobs", ["b"], status: "open") end)
    assert_received {:request, "GET", path, _}
    assert path =~ "/api/boards/b/jobs"
    assert path =~ "status=open"
    assert out =~ "running (stopping)"
    assert out =~ "dev/claude"

    out = capture_io(fn -> Runners.run("jobs", [], card: "12") end)
    assert_received {:request, "GET", "/api/cards/12/jobs", _}
    assert out =~ "no jobs"
  end

  test "job shows the prompt and the log tail" do
    serve([
      {200,
       ~s({"job":{"id":7,"status":"failed","card_id":12,"pool":"dev","kind":"claude","exit_code":1,"queued_at":"2026-10-08T10:00:00Z","prompt":"Do it","output":"boom"}})}
    ])

    out = capture_io(fn -> Runners.run("job", ["7"], []) end)
    assert out =~ "job #7  failed"
    assert out =~ "exit:     1"
    assert out =~ "  Do it"
    assert out =~ "  boom"
  end

  test "cancel-job says whether it stopped at once or was asked to" do
    serve([
      {200, ~s({"job":{"id":7,"status":"cancelled"}})},
      {200, ~s({"job":{"id":8,"status":"running"}})}
    ])

    assert capture_io(fn -> Runners.run("cancel-job", ["7"], []) end) =~ "cancelled job #7"
    assert_received {:request, "POST", "/api/jobs/7/cancel", _}

    assert capture_io(fn -> Runners.run("cancel-job", ["8"], []) end) =~
             "asked the runner to stop job #8"
  end

  test "claim-job: a job, or nothing queued" do
    serve([
      {200,
       ~s({"job":{"id":7,"kind":"claude","card_id":12,"card_url":"http://x/boards/1/cards/12","prompt":"Work on #12"},"lease_seconds":1200})},
      {200, ~s({"job":null})}
    ])

    out = capture_io(fn -> Runners.run("claim-job", ["b"], pool: "default") end)
    assert_received {:request, "POST", "/api/boards/b/jobs/claim", body}
    assert JSON.decode!(body) == %{"pool" => "default"}
    assert out =~ "claimed job #7 (claude) for card #12"
    assert out =~ "Work on #12"
    assert out =~ "lease 1200s"

    assert capture_io(fn -> Runners.run("claim-job", ["b"], pool: "default") end) =~
             "nothing queued"
  end

  test "job-progress sends the note and prints what the server says" do
    serve([{200, ~s({"status":"cancel"})}])
    out = capture_io(fn -> Runners.run("job-progress", ["7"], message: "halfway") end)
    assert_received {:request, "POST", "/api/jobs/7/progress", body}
    assert JSON.decode!(body) == %{"note" => "halfway"}
    assert out == "cancel\n"
  end

  test "finish-job defaults to done and sends the summary" do
    serve([
      {200, ~s({"job":{"id":7,"status":"done"}})},
      {200, ~s({"job":{"id":8,"status":"failed"}})}
    ])

    assert capture_io(fn -> Runners.run("finish-job", ["7"], summary: "fixed") end) =~
             "job #7 done"

    assert_received {:request, "POST", "/api/jobs/7/finish", body}
    assert JSON.decode!(body) == %{"outcome" => "done", "summary" => "fixed"}

    capture_io(fn -> Runners.run("finish-job", ["8"], status: "failed") end)
    assert_received {:request, "POST", "/api/jobs/8/finish", body}
    assert JSON.decode!(body) == %{"outcome" => "failed"}
  end
end
