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

  @setup ~s({"title":"Linux / macOS machine","intro":"Run this.","steps":[{"text":"On the machine, run:","code":"curl -fsSL x | sh -s -- --token sdr_secret"},{"text":"Nothing is sent until a rule sends it."}],"warnings":["watch out"],"cost":"free while idle"})

  test "runner new asks the wizard and prints its steps, token and all" do
    serve([
      {201,
       ~s({"runner":{"id":4,"name":"laptop","pool":"dev"},"token":"sdr_secret","automation":{"name":"Send Doing to the dev runners"},"setup":#{@setup}})}
    ])

    out =
      capture_io(fn ->
        Runners.run("runner", ["new", "b", "laptop"],
          pool: "dev",
          agent: "codex",
          cwd: "~/src",
          timeout: 900,
          column: ["Doing"]
        )
      end)

    assert_received {:request, "POST", "/api/boards/b/runners/setup", body}

    assert JSON.decode!(body) == %{
             "scenario" => "server",
             "name" => "laptop",
             "pool" => "dev",
             "agent" => "codex",
             "cwd" => "~/src",
             "timeout" => 900,
             "column" => "Doing"
           }

    assert out =~ "made runner #4 laptop for pool dev"
    assert out =~ "added the rule “Send Doing to the dev runners”"
    assert out =~ "1. On the machine, run:"
    assert out =~ "    curl -fsSL x | sh -s -- --token sdr_secret"
    assert out =~ "2. Nothing is sent until a rule sends it."
    assert out =~ "⚠ watch out"
    assert out =~ "free while idle"
  end

  test "runner new --top asks for a rule sending the list's top card, one at a time" do
    serve([{201, ~s({"runner":null,"token":null,"automation":null,"setup":#{@setup}})}])

    capture_io(fn ->
      Runners.run("runner", ["new", "b"], scenario: "loop", column: ["To Do"], top: true)
    end)

    assert_received {:request, "POST", "/api/boards/b/runners/setup", body}
    assert %{"column" => "To Do", "feed" => "top"} = body = JSON.decode!(body)
    refute Map.has_key?(body, "wait")
  end

  test "runner new passes --requeue-stuck as the number of times to put a card back" do
    serve([
      {201, ~s({"runner":null,"token":null,"automation":null,"setup":#{@setup}})},
      {201, ~s({"runner":null,"token":null,"automation":null,"setup":#{@setup}})}
    ])

    capture_io(fn ->
      Runners.run("runner", ["new", "b"],
        scenario: "loop",
        column: ["To Do"],
        top: true,
        requeue_stuck: 2
      )

      Runners.run("runner", ["new", "b"], scenario: "loop", column: ["To Do"], top: true)
    end)

    assert_received {:request, "POST", _, with}
    assert %{"requeue" => 2, "feed" => "top"} = JSON.decode!(with)
    assert_received {:request, "POST", _, without}
    refute Map.has_key?(JSON.decode!(without), "requeue")
  end

  test "runner new passes --no-wait-while-doing and --wait-while-doing on" do
    serve([
      {201, ~s({"runner":null,"token":null,"automation":null,"setup":#{@setup}})},
      {201, ~s({"runner":null,"token":null,"automation":null,"setup":#{@setup}})}
    ])

    capture_io(fn ->
      Runners.run("runner", ["new", "b"],
        scenario: "loop",
        column: ["To Do"],
        top: true,
        wait_while_doing: false
      )

      Runners.run("runner", ["new", "b"],
        scenario: "loop",
        column: ["Doing"],
        wait_while_doing: true
      )
    end)

    assert_received {:request, "POST", _, off}
    assert %{"wait" => "no"} = JSON.decode!(off)
    assert_received {:request, "POST", _, on}
    assert %{"wait" => "yes", "column" => "Doing"} = JSON.decode!(on)
  end

  test "a queued job held back says why" do
    job = %{"id" => 7, "card_id" => 3, "pool" => "loop", "kind" => "claude", "attempts" => 0}

    out =
      capture_io(fn ->
        SlipdockCLI.Render.job(
          Map.merge(job, %{"status" => "queued", "waiting_on" => "#12 is in progress"})
        )

        SlipdockCLI.Render.job(Map.merge(job, %{"status" => "queued", "waiting_on" => nil}))
      end)

    assert out =~ "job #7  queued (waiting: #12 is in progress)  card #3"
    assert out =~ ~r/job #7  queued  card #3/
  end

  test "claim-job says when a job is held back while something is in progress" do
    serve([
      {200, ~s({"job":null,"waiting":{"job":7,"card_id":3,"reason":"#12 is in progress"}})},
      {200, ~s({"job":null})}
    ])

    out = capture_io(fn -> Runners.run("claim-job", ["b"], pool: "loop") end)
    assert out =~ "nothing queued to take: job #7 waits while #12 is in progress"
    assert capture_io(fn -> Runners.run("claim-job", ["b"], pool: "loop") end) =~ "nothing queued"
  end

  test "runner new and setup pass the Slipdock tools option, on, off or for named servers" do
    serve([
      {201, ~s({"runner":null,"token":null,"automation":null,"setup":#{@setup}})},
      {200, ~s({"setup":#{@setup},"diff":[]})}
    ])

    capture_io(fn ->
      Runners.run("runner", ["new", "b"], pool: "dev", mcp_servers: "my-slipdock")
    end)

    assert_received {:request, "POST", "/api/boards/b/runners/setup", body}
    assert JSON.decode!(body)["mcp_servers"] == "my-slipdock"
    refute Map.has_key?(JSON.decode!(body), "slipdock_tools")

    capture_io(fn -> Runners.run("runner", ["setup", "b", "4"], slipdock_tools: false) end)
    assert_received {:request, "PUT", "/api/boards/b/runners/4/setup", body}
    assert JSON.decode!(body) == %{"slipdock_tools" => false}
  end

  test "--no-slipdock-tools and --mcp-servers are options the CLI parses" do
    assert {[slipdock_tools: false, mcp_servers: "a,b"], [], []} =
             OptionParser.parse(["--no-slipdock-tools", "--mcp-servers", "a,b"],
               strict: SlipdockCLI.switches()
             )
  end

  test "runner new for a Claude scenario needs no pool and makes no runner" do
    serve([{201, ~s({"runner":null,"token":null,"automation":null,"setup":#{@setup}})}])
    out = capture_io(fn -> Runners.run("runner", ["new", "b"], scenario: "loop") end)
    assert_received {:request, "POST", "/api/boards/b/runners/setup", body}
    assert JSON.decode!(body) == %{"scenario" => "loop"}
    refute out =~ "made runner"
    assert out =~ "1. On the machine, run:"
  end

  test "runner setup and runner token" do
    serve([
      {200, ~s({"setup":#{@setup}})},
      {200, ~s({"token":"sdr_new","runner":{"name":"laptop"},"setup":#{@setup}})}
    ])

    assert capture_io(fn -> Runners.run("runner", ["setup", "b", "4"], []) end) =~ "Run this."
    assert_received {:request, "GET", "/api/boards/b/runners/4/setup", _}

    out = capture_io(fn -> Runners.run("runner", ["token", "b", "4"], []) end)
    assert_received {:request, "POST", "/api/boards/b/runners/4/token", _}
    assert out =~ "new token for laptop"
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

  test "runner setup with new answers saves them and prints what changes first" do
    serve([
      {200,
       ~s({"diff":[["eq","curl …"],["del","  --timeout 3600"],["ins","  --timeout 900"],["ins","  --instructions 'Be brief.'"]],"setup":#{@setup}})}
    ])

    out =
      capture_io(fn ->
        Runners.run("runner", ["setup", "b", "4"],
          timeout: 900,
          instructions: "Be brief.",
          after_job: "echo done"
        )
      end)

    assert_received {:request, "PUT", "/api/boards/b/runners/4/setup", body}

    assert JSON.decode!(body) == %{
             "timeout" => 900,
             "instructions" => "Be brief.",
             "after_job" => "echo done"
           }

    assert out =~ "- " <> "  --timeout 3600"
    assert out =~ "+   --instructions 'Be brief.'"
    refute out =~ "curl …\n+"
    assert out =~ "1. On the machine, run:"
  end
end
