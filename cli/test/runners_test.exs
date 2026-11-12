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

  @setup ~s({"title":"A machine with the daemon","intro":"Run this.","steps":[{"text":"Install the daemon.","code":"slipdock-runner init --server x --key sde_once"},{"text":"Nothing is sent until a rule sends it."}],"warnings":["watch out"],"cost":"free while idle"})

  test "runner new asks the wizard for the daemon by default, and prints its steps" do
    serve([
      {201,
       ~s({"runner":null,"token":null,"enrolment_key":"sde_once","automation":{"name":"Send Doing to the dev runners"},"setup":#{@setup}})}
    ])

    out =
      capture_io(fn ->
        Runners.run("runner", ["new", "b", "laptop"], pool: "dev", column: ["Doing"])
      end)

    assert_received {:request, "POST", "/api/boards/b/runners/setup", body}

    # The shell runners were retired (#2582): the daemon is the default, and
    # the name and the script runners' options are no longer sent.
    assert JSON.decode!(body) == %{"scenario" => "daemon", "pool" => "dev", "column" => "Doing"}

    refute out =~ "made runner"
    assert out =~ "its enrolment key is in the steps below, shown this once"
    assert out =~ "added the rule “Send Doing to the dev runners”"
    assert out =~ "1. Install the daemon."
    assert out =~ "2. Nothing is sent until a rule sends it."
    assert out =~ "⚠ watch out"
    assert out =~ "free while idle"
  end

  test "the script runners' switches are gone: the CLI refuses them as unknown" do
    for flag <-
          ~w(--no-self-update --self-update --install-name --service --no-slipdock-tools --mcp-servers --hook-prompt --command --timeout) do
      {_, _, invalid} = OptionParser.parse([flag, "x"], strict: SlipdockCLI.switches())
      assert [{^flag, _}] = invalid, flag
    end
  end

  test "runner setup takes no answers: it only shows the steps to move onto a machine" do
    serve([{200, ~s({"setup":#{@setup}})}])

    out =
      capture_io(fn ->
        Runners.run("runner", ["setup", "b", "4"], instructions: "Be brief.", commit: true)
      end)

    assert_received {:request, "GET", "/api/boards/b/runners/4/setup", _}
    refute_received {:request, "PUT", _, _}
    assert out =~ "Run this."
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

  test "runner new --alert asks for the trouble rule, and says it was added" do
    serve([
      {201,
       ~s({"runner":null,"token":null,"automation":null,"alert_automation":{"id":9,"name":"Trouble on the loop runners"},"setup":#{@setup}})}
    ])

    out =
      capture_io(fn ->
        Runners.run("runner", ["new", "b"], scenario: "loop", pool: "loop", alert: true)
      end)

    assert_received {:request, "POST", _, body}
    assert %{"alert" => "yes"} = JSON.decode!(body)
    assert out =~ "added the rule “Trouble on the loop runners”"
  end

  test "runner show asks for one runner and prints it in full (#526)" do
    serve([
      {200,
       ~s({"runner":{"id":4,"name":"laptop","pool":"dev","session":false,"settings":{"scenario":"server"},"created_at":"2026-10-01T10:00:00Z","created_by":"David","last_seen_at":null,"api_token":null,"current_job":{"id":9,"status":"running","card_id":12,"card":"Fix it"},"job_counts":{"done":3,"failed":1},"jobs_total":4,"rules":[{"id":2,"name":"Feeds dev"}],"recent_jobs":[{"id":9,"status":"running","card_id":12,"card":"Fix it","pool":"dev","kind":"claude","runner":"laptop","queued_at":"2026-10-01T10:00:00Z"}]}})}
    ])

    out = capture_io(fn -> Runners.run("runner", ["show", "b", "laptop"], limit: 3) end)

    assert_received {:request, "GET", path, _}
    assert path =~ "/api/boards/b/runners/laptop"
    assert path =~ "limit=3"

    assert out =~
             "runner #4 laptop  pool dev  (runner with its own token: a retired shell runner)"

    assert out =~ "by David"
    assert out =~ "seen:      never"
    assert out =~ "now:       job #9 running on card #12 Fix it"
    assert out =~ "jobs:      4 (3 done, 1 failed)"
    assert out =~ "rules:     #2 Feeds dev"
    assert out =~ "latest jobs:"
  end

  test "runner show for an idle session with no jobs or rules" do
    serve([
      {200,
       ~s({"runner":{"id":5,"name":"desktop","pool":"loop","session":true,"settings":{},"created_at":"2026-10-01T10:00:00Z","created_by":null,"last_seen_at":"2026-10-02T10:00:00Z","api_token":{"id":7,"label":"desktop","scope":"write"},"current_job":null,"job_counts":{},"jobs_total":0,"rules":[],"recent_jobs":[]}})}
    ])

    out = capture_io(fn -> Runners.run("runner", ["show", "b", "desktop"], []) end)

    assert out =~ "(Claude session)"
    assert out =~ "api token: desktop (write)"
    assert out =~ "now:       idle"
    assert out =~ "jobs:      0\n"
    assert out =~ "none send cards to this pool"
    refute out =~ "latest jobs"
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

  test "the seven toggles parse as --[no-]flags, are sent as given, and left out unset" do
    args =
      ~w(--in-progress --assign --commit --push --move-done --complete --percent-100 --verbosity nothing)

    assert {opts, [], []} = OptionParser.parse(args, strict: SlipdockCLI.switches())

    assert opts == [
             in_progress: true,
             assign: true,
             commit: true,
             push: true,
             move_done: true,
             complete: true,
             percent_100: true,
             verbosity: "nothing"
           ]

    assert {[commit: false, push: false], [], []} =
             OptionParser.parse(~w(--no-commit --no-push), strict: SlipdockCLI.switches())

    # The old answers are gone: --commit takes no value, --close is unknown.
    assert {[commit: true], ["push", "done"], [{"--close", nil}]} =
             OptionParser.parse(~w(--commit push --close done), strict: SlipdockCLI.switches())

    serve([{201, ~s({"runner":null,"token":null,"automation":null,"setup":#{@setup}})}])

    capture_io(fn ->
      Runners.run("runner", ["new", "b"], [scenario: "loop"] ++ Keyword.delete(opts, :verbosity))
    end)

    assert_received {:request, "POST", "/api/boards/b/runners/setup", body}

    assert JSON.decode!(body) == %{
             "scenario" => "loop",
             "in_progress" => true,
             "assign" => true,
             "commit" => true,
             "push" => true,
             "move_done" => true,
             "complete" => true,
             "percent_100" => true
           }
  end

  test "runner new for a Claude scenario needs no pool and makes no runner" do
    serve([{201, ~s({"runner":null,"token":null,"automation":null,"setup":#{@setup}})}])
    out = capture_io(fn -> Runners.run("runner", ["new", "b"], scenario: "loop") end)
    assert_received {:request, "POST", "/api/boards/b/runners/setup", body}
    assert JSON.decode!(body) == %{"scenario" => "loop"}
    refute out =~ "made runner"
    assert out =~ "1. Install the daemon."
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

  # #1668: a step shows on the job, not as a comment on the card.
  test "job-progress --step sends the step, and no note" do
    serve([{200, ~s({"status":"ok"})}])

    out =
      capture_io(fn -> Runners.run("job-progress", ["7"], step: "tests running: mix test") end)

    assert_received {:request, "POST", "/api/jobs/7/progress", body}
    assert JSON.decode!(body) == %{"step" => "tests running: mix test"}
    assert out == "ok\n"
  end

  test "job-progress with no id reports on the runner job in $SLIPDOCK_JOB_ID" do
    saved = System.get_env("SLIPDOCK_JOB_ID")
    System.put_env("SLIPDOCK_JOB_ID", " 42 ")

    on_exit(fn ->
      if saved,
        do: System.put_env("SLIPDOCK_JOB_ID", saved),
        else: System.delete_env("SLIPDOCK_JOB_ID")
    end)

    serve([{200, ~s({"status":"ok"})}])
    capture_io(fn -> Runners.run("job-progress", [], step: "judging against the bar") end)
    assert_received {:request, "POST", "/api/jobs/42/progress", body}
    assert JSON.decode!(body) == %{"step" => "judging against the bar"}
  end

  test "job and jobs show a job's latest step" do
    job = %{
      "id" => 7,
      "card_id" => 3,
      "card" => "Export header",
      "pool" => "checkers",
      "kind" => "verify",
      "status" => "running",
      "attempts" => 1,
      "runner" => "box",
      "step" => "tests passed: 412, failed: 0",
      "step_at" => "2026-11-03T15:00:00Z",
      "queued_at" => "2026-11-03T14:58:00Z"
    }

    one = capture_io(fn -> SlipdockCLI.Render.job(job) end)
    assert one =~ "step:     tests passed: 412, failed: 0"

    many = capture_io(fn -> SlipdockCLI.Render.jobs([job, %{job | "id" => 8, "step" => nil}]) end)
    assert many =~ "STEP"
    assert many =~ "tests passed: 412, failed: 0"

    refute capture_io(fn -> SlipdockCLI.Render.job(%{job | "step" => nil}) end) =~ "step:"
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

  describe "skill and CLI drift (#1795)" do
    defp drifting(drift) do
      %{
        "id" => 4,
        "name" => "laptop",
        "pool" => "dev",
        "session" => false,
        "settings" => %{},
        "created_at" => "2026-11-03T10:00:00Z",
        "last_seen_at" => nil,
        "kinds" => ["claude"],
        "missing_kinds" => [],
        "drift" => drift,
        "current_job" => nil,
        "stats" => %{},
        "jobs" => [],
        "rules" => []
      }
    end

    test "the list shows current, drifted with the names, old and unknown" do
      out =
        capture_io(fn ->
          SlipdockCLI.Render.runners([
            drifting(%{"skills" => "current", "drifted_skills" => [], "cli" => "current"}),
            Map.put(
              drifting(%{
                "skills" => "drifted",
                "drifted_skills" => ["slipdock-loop"],
                "cli" => "old"
              }),
              "id",
              5
            ),
            Map.put(drifting(nil), "id", 6),
            Map.put(
              drifting(%{"skills" => "current", "drifted_skills" => [], "cli" => "unsigned"}),
              "id",
              7
            ),
            Map.put(
              drifting(%{
                "skills" => "unsigned",
                "drifted_skills" => ["slipdock-loop"],
                "cli" => "current"
              }),
              "id",
              8
            )
          ])
        end)

      assert out =~ "SKILLS · CLI"
      assert out =~ "skills current · cli current"
      assert out =~ "skills drifted (slipdock-loop) · cli old"
      assert out =~ "skills unknown · cli unknown"
      assert out =~ "skills current · cli unsigned on server"
      assert out =~ "skills unsigned on server (slipdock-loop) · cli current"
    end

    test "one runner says each on its own line; a session shows none" do
      out =
        capture_io(fn ->
          SlipdockCLI.Render.runner(
            drifting(%{"skills" => "drifted", "drifted_skills" => ["slipdock"], "cli" => "none"})
          )
        end)

      assert out =~ "skills:    drifted (slipdock)"
      assert out =~ "cli:       none"

      assert SlipdockCLI.Render.drift_cell(%{"session" => true}) =~ "-"

      out =
        capture_io(fn ->
          SlipdockCLI.Render.runner(
            drifting(%{"skills" => "current", "drifted_skills" => [], "cli" => "unsigned"})
          )
        end)

      assert out =~ "cli:       unsigned on server"

      out =
        capture_io(fn ->
          SlipdockCLI.Render.runner(
            drifting(%{
              "skills" => "unsigned",
              "drifted_skills" => ["slipdock"],
              "cli" => "current"
            })
          )
        end)

      assert out =~ "skills:    unsigned on server (slipdock)"
    end

    # A drift that names no skills (no `drifted_skills` key) still names the
    # server, never a bare `unsigned` that reads as the machine's (#2916).
    test "unsigned skills with no names still say it is the server's" do
      drift = %{"skills" => "unsigned", "cli" => "current"}

      table = capture_io(fn -> SlipdockCLI.Render.runners([drifting(drift)]) end)
      assert table =~ "skills unsigned on server · cli current"
      refute table =~ "unsigned on server ("

      one = capture_io(fn -> SlipdockCLI.Render.runner(drifting(drift)) end)
      assert one =~ "skills:    unsigned on server\n"
    end
  end
end
