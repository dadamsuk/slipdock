defmodule SlipdockWeb.RunnerScriptTest do
  # The shell runner (`priv/runner/slipdock-runner`), run for real under
  # `sh` against this app served on a loopback port: claiming, running a job
  # kind from its config, heartbeats, cancel, timeout and finishing — and that
  # nothing the server sends is ever run as a command.
  #
  # Sync: the requests arrive on the HTTP server's own processes, which share
  # this test's sandbox connection.
  use Slipdock.DataCase, async: false

  import Slipdock.Fixtures

  alias Slipdock.{Repo, Runners}
  alias Slipdock.Runners.Job

  @script Path.expand("../../priv/runner/slipdock-runner", __DIR__)

  setup do
    {:ok, server} =
      Bandit.start_link(
        plug: SlipdockWeb.Endpoint,
        ip: {127, 0, 0, 1},
        port: 0,
        startup_log: false
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    on_exit(fn -> Process.exit(server, :normal) end)

    dir = Path.join(System.tmp_dir!(), "slipdock-runner-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    board = board_fixture()
    card = card_fixture(hd(board.columns), %{"title" => "Run me"})
    {:ok, runner, token} = Runners.create_runner(board, %{"name" => "sh", "pool" => "dev"})

    %{url: "http://127.0.0.1:#{port}", dir: dir, card: card, runner: runner, token: token}
  end

  # A config like the installer writes, with test kinds and quick timings.
  defp config(ctx, extra \\ "") do
    path = Path.join(ctx.dir, "config")

    File.write!(path, """
    SLIPDOCK_URL='#{ctx.url}'
    SLIPDOCK_RUNNER_TOKEN='#{ctx.token}'
    WAIT=0
    HEARTBEAT=1
    JOB_TIMEOUT=30
    GRACE=2
    OUT='#{ctx.dir}/out'
    job_echo() { printf '%s' "$SLIPDOCK_PROMPT" >"$OUT"; echo "card $SLIPDOCK_CARD job $SLIPDOCK_JOB_ID"; }
    job_fail() { echo "about to fail"; exit 3; }
    job_sleep() { echo started; sleep 60 & echo $! >"#{ctx.dir}/child"; wait; echo never; }
    #{extra}
    """)

    path
  end

  defp run_once(ctx, config, env \\ [], shell \\ "sh") do
    System.cmd(shell, [@script, "--once", "--config=#{config}"],
      cd: ctx.dir,
      env: [{"TMPDIR", ctx.dir} | env],
      stderr_to_stdout: true
    )
  end

  defp queue(card, kind, prompt \\ "go"),
    do: Runners.queue(card, %{pool: "dev", kind: kind, prompt: prompt})

  defp job(job), do: Repo.get!(Job, job.id)

  defp alive?(pid), do: match?({_, 0}, System.cmd("kill", ["-0", pid], stderr_to_stdout: true))

  defp wait_for(fun, tries \\ 100) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("timed out waiting")
      true -> Process.sleep(100) && wait_for(fun, tries - 1)
    end
  end

  test "takes a job, runs its kind with the card in the environment, and finishes it", ctx do
    {:ok, queued} = queue(ctx.card, "echo", "Fix the login page")
    {out, 0} = run_once(ctx, config(ctx))

    assert out =~ "job ##{queued.id}: echo for card ##{ctx.card.id}"
    assert File.read!(Path.join(ctx.dir, "out")) == "Fix the login page"

    done = job(queued)
    assert done.status == "done"
    assert done.exit_code == 0
    assert done.output == "card #{ctx.card.id} job #{queued.id}\n"
    assert done.runner_id == ctx.runner.id
  end

  # macOS's /bin/sh is bash in POSIX mode; CI's is dash. Both, then.
  @tag :bash
  test "bash runs it the same as dash", ctx do
    if System.find_executable("bash") do
      {:ok, queued} = queue(ctx.card, "echo", "under bash")
      {_out, 0} = run_once(ctx, config(ctx), [], "bash")
      assert job(queued).status == "done"
      assert File.read!(Path.join(ctx.dir, "out")) == "under bash"

      {:ok, queued} = queue(ctx.card, "sleep")
      {_out, 0} = run_once(ctx, config(ctx, "JOB_TIMEOUT=2"), [], "bash")
      assert job(queued).status == "timeout"
      refute alive?(ctx.dir |> Path.join("child") |> File.read!() |> String.trim())
    end
  end

  test "with nothing queued, --once asks once and leaves", ctx do
    assert {out, 0} = run_once(ctx, config(ctx))
    refute out =~ "job #"
  end

  test "a prompt full of shell is passed through as text and never run", ctx do
    prompt = ~S"""
    "; touch PWNED1; echo "
    $(touch PWNED2)
    `touch PWNED3`
    '; touch PWNED4 #
    ${HOME:?} \n done
    """

    {:ok, queued} = queue(ctx.card, "echo", prompt)
    {_out, 0} = run_once(ctx, config(ctx))

    assert job(queued).status == "done"
    # The prompt arrives whole (command substitution only trims the end).
    assert File.read!(Path.join(ctx.dir, "out")) == String.trim_trailing(prompt)
    assert Path.wildcard(Path.join(ctx.dir, "PWNED*")) == []
  end

  test "an unknown kind is refused with 127 and nothing runs — not even a program by that name",
       ctx do
    bin = Path.join(ctx.dir, "bin")
    File.mkdir_p!(bin)
    evil = Path.join(bin, "job_evil")
    File.write!(evil, "#!/bin/sh\ntouch '#{ctx.dir}/RAN'\n")
    File.chmod!(evil, 0o755)

    {:ok, queued} = queue(ctx.card, "evil")
    {out, 0} = run_once(ctx, config(ctx), [{"PATH", "#{bin}:#{System.get_env("PATH")}"}])

    assert out =~ "no job_evil"
    refute File.exists?(Path.join(ctx.dir, "RAN"))

    refused = job(queued)
    assert {refused.status, refused.exit_code} == {"failed", 127}
    assert refused.error == "the runner has no such job kind"
    assert refused.output =~ "no such job kind: evil"
  end

  test "a kind with a dash runs the function with an underscore", ctx do
    {:ok, queued} = queue(ctx.card, "two-words")
    {_out, 0} = run_once(ctx, config(ctx, "job_two_words() { echo dashed; }"))
    assert %{status: "done", output: "dashed\n"} = job(queued)
  end

  test "a failing job is failed with its exit code and the end of its log", ctx do
    {:ok, queued} = queue(ctx.card, "fail")
    {_out, 0} = run_once(ctx, config(ctx))
    assert %{status: "failed", exit_code: 3, output: "about to fail\n"} = job(queued)
  end

  test "a job over its time is stopped, children and all, and reported as a timeout", ctx do
    {:ok, queued} = queue(ctx.card, "sleep")
    cfg = config(ctx, "JOB_TIMEOUT=2")
    {out, 0} = run_once(ctx, cfg)

    assert out =~ "over its 2s"
    stopped = job(queued)
    assert {stopped.status, stopped.exit_code} == {"timeout", 124}
    assert stopped.output =~ "started"
    assert stopped.output =~ "stopped after 2s"
    refute stopped.output =~ "never"

    child = ctx.dir |> Path.join("child") |> File.read!() |> String.trim()
    refute alive?(child)
  end

  test "a job cancelled from the board is stopped on the next heartbeat", ctx do
    {:ok, queued} = queue(ctx.card, "sleep")
    cfg = config(ctx)
    running = Task.async(fn -> run_once(ctx, cfg) end)

    wait_for(fn -> job(queued).status == "running" end)
    {:ok, _} = Runners.cancel_job(job(queued))

    {out, 0} = Task.await(running, 20_000)
    assert out =~ "cancelled from the board"
    assert %{status: "cancelled", exit_code: 130} = job(queued)

    child = ctx.dir |> Path.join("child") |> File.read!() |> String.trim()
    refute alive?(child)
  end

  test "heartbeats carry the log while the job runs", ctx do
    {:ok, queued} = queue(ctx.card, "sleep")
    cfg = config(ctx)
    running = Task.async(fn -> run_once(ctx, cfg) end)

    wait_for(fn -> (job(queued).log_tail || "") =~ "started" end)
    {:ok, _} = Runners.cancel_job(job(queued))
    Task.await(running, 20_000)
  end

  test "a token the server refuses stops the runner with a reason", ctx do
    {:ok, _} = Runners.delete_runner(ctx.runner)
    {out, 1} = run_once(ctx, config(ctx))
    assert out =~ "the server refused this runner (HTTP 401)"
  end

  test "an unreachable server is an error under --once, not a hang", ctx do
    cfg = Path.join(ctx.dir, "config")
    config(ctx)
    File.write!(cfg, String.replace(File.read!(cfg), ctx.url, "http://127.0.0.1:1"))
    {out, 1} = run_once(ctx, cfg)
    assert out =~ "could not reach the queue (HTTP 000)"
  end

  test "a missing config says where it looked", ctx do
    {out, 2} = run_once(ctx, Path.join(ctx.dir, "nope"))
    assert out =~ "no config at"
  end

  test "the token never appears on a command line", ctx do
    # It goes to curl in a file: the script has no `Bearer $TOKEN` argument.
    script = File.read!(@script)
    refute script =~ ~r/-H\s+["']Authorization/
    assert script =~ ~s(-H @"$WORK/auth")
    _ = ctx
  end

  test "what install.sh writes takes and runs a job as it stands", ctx do
    home = Path.join(ctx.dir, "home")
    File.mkdir_p!(home)
    installer = Path.join(ctx.dir, "install.sh")
    File.write!(installer, SlipdockWeb.RunnerInstallController.files()["install.sh"])

    {_, 0} =
      System.cmd(
        "sh",
        [installer, "--url", ctx.url, "--token", ctx.token, "--pool", "dev", "--cwd", ctx.dir] ++
          ~w(--service none --no-start),
        # CI sets XDG_CONFIG_HOME, which would send the config out of HOME.
        env: [{"HOME", home}, {"XDG_CONFIG_HOME", nil}],
        stderr_to_stdout: true
      )

    {:ok, queued} = queue(ctx.card, "echo", "installed and working")

    {out, 0} =
      System.cmd(Path.join(home, ".local/bin/slipdock-runner"), ["--once"],
        env: [{"HOME", home}, {"XDG_CONFIG_HOME", nil}, {"TMPDIR", ctx.dir}],
        stderr_to_stdout: true
      )

    assert out =~ "(pool dev)"
    assert %{status: "done", output: "installed and working\n"} = job(queued)
  end

  describe "instructions and hooks" do
    defp hooks(ctx),
      do: """
      after_job() { echo "$SLIPDOCK_STATUS $SLIPDOCK_EXIT $SLIPDOCK_JOB_ID" >>'#{ctx.dir}/after'; echo "after ran"; }
      """

    defp after_lines(ctx),
      do: ctx.dir |> Path.join("after") |> File.read!() |> String.split("\n", trim: true)

    test "after_job runs once a job is done, with its status and exit", ctx do
      {:ok, queued} = queue(ctx.card, "echo")
      {_, 0} = run_once(ctx, config(ctx, hooks(ctx)))
      assert after_lines(ctx) == ["done 0 #{queued.id}"]
      assert job(queued).output =~ "after ran"
    end

    test "after_job runs when the job fails", ctx do
      {:ok, queued} = queue(ctx.card, "fail")
      {_, 0} = run_once(ctx, config(ctx, hooks(ctx)))
      assert after_lines(ctx) == ["failed 3 #{queued.id}"]
      assert job(queued).status == "failed"
    end

    test "after_job runs when the job times out", ctx do
      {:ok, queued} = queue(ctx.card, "sleep")
      {_, 0} = run_once(ctx, config(ctx, "JOB_TIMEOUT=2\n" <> hooks(ctx)))
      assert after_lines(ctx) == ["timeout 124 #{queued.id}"]
    end

    test "after_job runs when the job is cancelled", ctx do
      {:ok, queued} = queue(ctx.card, "sleep")
      cfg = config(ctx, hooks(ctx))
      running = Task.async(fn -> run_once(ctx, cfg) end)
      wait_for(fn -> job(queued).status == "running" end)
      {:ok, _} = Runners.cancel_job(job(queued))
      Task.await(running, 20_000)
      assert after_lines(ctx) == ["cancelled 130 #{queued.id}"]
    end

    test "a before_job that fails means the job never runs", ctx do
      {:ok, queued} = queue(ctx.card, "echo", "should not be echoed")
      {out, 0} = run_once(ctx, config(ctx, "before_job() { echo nope; exit 5; }\n" <> hooks(ctx)))

      assert out =~ "before_job failed (exit 5)"
      refute File.exists?(Path.join(ctx.dir, "out"))
      assert %{status: "failed", exit_code: 5, output: output} = job(queued)
      assert output =~ "nope"
      assert output =~ "so the job was not run"
      assert after_lines(ctx) == ["failed 5 #{queued.id}"]
    end

    test "a before_job that succeeds runs first", ctx do
      {:ok, queued} = queue(ctx.card, "echo")
      {_, 0} = run_once(ctx, config(ctx, "before_job() { echo 'before ran'; }"))
      assert %{status: "done", output: "before ran\n" <> _} = job(queued)
    end

    test "standing instructions from install.sh reach the prompt word for word", ctx do
      instructions = ~S"""
      Say "hi" and it's fine. $(touch PWNED) `touch PWNED` ${HOME}
      SLIPDOCK_EOF_deadbeef
      'quoted' — naïve café ✓
      """

      home = Path.join(ctx.dir, "home")
      File.mkdir_p!(home)
      installer = Path.join(ctx.dir, "install.sh")
      File.write!(installer, SlipdockWeb.RunnerInstallController.files()["install.sh"])

      {_, 0} =
        System.cmd(
          "sh",
          [installer, "--url", ctx.url, "--token", ctx.token, "--pool", "dev", "--cwd", ctx.dir] ++
            ["--instructions", String.trim(instructions)] ++ ~w(--service none --no-start),
          env: [{"HOME", home}, {"XDG_CONFIG_HOME", nil}],
          cd: ctx.dir,
          stderr_to_stdout: true
        )

      {:ok, queued} = queue(ctx.card, "echo", "The card's prompt.")

      {_, 0} =
        System.cmd(Path.join(home, ".local/bin/slipdock-runner"), ["--once"],
          env: [{"HOME", home}, {"XDG_CONFIG_HOME", nil}, {"TMPDIR", ctx.dir}],
          cd: ctx.dir,
          stderr_to_stdout: true
        )

      assert job(queued).output == "The card's prompt.\n\n" <> instructions
      assert Path.wildcard(Path.join([ctx.dir, "**", "PWNED"])) == []
    end
  end
end
