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
  alias SlipdockWeb.FlakyTranscripts, as: Flaky

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

  test "a verify job runs job_verify on its own prompt, without the standing instructions",
       ctx do
    extra = """
    JOB_INSTRUCTIONS='Work this card with /slipdock-loop.'
    job_verify() { printf '%s' "$SLIPDOCK_PROMPT" >"$OUT"; }
    """

    {:ok, queued} = queue(ctx.card, "verify", "Check card 1 against its bar.")
    {_, 0} = run_once(ctx, config(ctx, extra))
    assert File.read!(Path.join(ctx.dir, "out")) == "Check card 1 against its bar."
    assert job(queued).status == "done"

    {:ok, _} = queue(ctx.card, "echo", "Do the card.")
    {_, 0} = run_once(ctx, config(ctx, extra))
    assert File.read!(Path.join(ctx.dir, "out")) =~ "Work this card with /slipdock-loop."
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

  describe "worktrees (lanes)" do
    # A repository with one commit, the runner pointed at it with WORKTREE on.
    defp repo(ctx) do
      repo = Path.join(ctx.dir, "repo")
      File.mkdir_p!(repo)
      git(repo, ["init", "-q", "-b", "main"])
      File.write!(Path.join(repo, "README"), "hi\n")
      git(repo, ["add", "README"])
      git(repo, ["commit", "-q", "-m", "first"])
      repo
    end

    defp git(dir, args) do
      {out, 0} =
        System.cmd("git", ["-c", "user.name=t", "-c", "user.email=t@example.com" | args],
          cd: dir,
          stderr_to_stdout: true
        )

      out
    end

    defp lanes(ctx, repo, extra \\ "") do
      config(ctx, """
      WORKTREE=1
      WORKTREE_REPO='#{repo}'
      job_pwd() { pwd >"$OUT"; echo "wt=${SLIPDOCK_WORKTREE:-}"; }
      job_dirty() { pwd >"$OUT"; echo scratch >scratch.txt; }
      job_commit() { echo more >>README && git -c user.name=t -c user.email=t@example.com commit -qam more; }
      #{extra}
      """)
    end

    defp lane_path(repo, card), do: "#{repo}-lanes/card-#{card.id}"

    test "on: the job runs in a worktree on the card's branch, removed after", ctx do
      repo = repo(ctx)
      {:ok, queued} = queue(ctx.card, "pwd")
      {_, 0} = run_once(ctx, lanes(ctx, repo))

      path = lane_path(repo, ctx.card)
      assert ctx.dir |> Path.join("out") |> File.read!() |> String.trim() == path

      assert %{status: "done", output: output} = job(queued)
      assert output =~ "worktree #{path} on branch card-#{ctx.card.id}"
      assert output =~ "wt=#{path}"
      assert output =~ "worktree #{path} removed"

      refute File.exists?(path)
      refute git(repo, ["branch", "--list", "card-#{ctx.card.id}"]) =~ "card-"
      refute git(repo, ["worktree", "list"]) =~ "-lanes"
    end

    test "on: before_job and after_job run inside the worktree too", ctx do
      repo = repo(ctx)
      {:ok, _} = queue(ctx.card, "pwd")

      hooks = """
      before_job() { pwd >'#{ctx.dir}/before'; }
      after_job() { pwd >'#{ctx.dir}/after'; }
      """

      {_, 0} = run_once(ctx, lanes(ctx, repo, hooks))
      path = lane_path(repo, ctx.card)
      assert ctx.dir |> Path.join("before") |> File.read!() |> String.trim() == path
      assert ctx.dir |> Path.join("after") |> File.read!() |> String.trim() == path
    end

    test "off: the job runs where the runner does, and no worktree is made", ctx do
      repo = repo(ctx)
      {:ok, queued} = queue(ctx.card, "pwd")
      {_, 0} = run_once(ctx, lanes(ctx, repo, "WORKTREE=0"))

      assert ctx.dir |> Path.join("out") |> File.read!() |> String.trim() == ctx.dir
      refute job(queued).output =~ "worktree"
      refute File.exists?("#{repo}-lanes")
    end

    test "a worktree with uncommitted changes is kept, and the next job on the card reuses it",
         ctx do
      repo = repo(ctx)
      path = lane_path(repo, ctx.card)

      {:ok, first} = queue(ctx.card, "dirty")
      {_, 0} = run_once(ctx, lanes(ctx, repo))
      assert job(first).output =~ "worktree #{path} has uncommitted changes, so it is kept"
      assert File.read!(Path.join(path, "scratch.txt")) == "scratch\n"

      {:ok, second} = queue(ctx.card, "pwd")
      {_, 0} = run_once(ctx, lanes(ctx, repo))
      assert %{status: "done", output: output} = job(second)
      assert output =~ "worktree #{path} (kept from before) on card-#{ctx.card.id}"
      # Still dirty from the first job, so still kept.
      assert output =~ "so it is kept"
      assert File.exists?(Path.join(path, "scratch.txt"))
    end

    test "a clean worktree with a commit is removed but its unmerged branch kept", ctx do
      repo = repo(ctx)
      {:ok, queued} = queue(ctx.card, "commit")
      {_, 0} = run_once(ctx, lanes(ctx, repo))

      path = lane_path(repo, ctx.card)
      assert job(queued).output =~ "worktree #{path} removed; branch card-#{ctx.card.id} kept"
      refute File.exists?(path)
      assert git(repo, ["log", "--oneline", "card-#{ctx.card.id}"]) =~ "more"
    end

    test "a directory that is not a git repository runs the job in place, saying so", ctx do
      plain = Path.join(ctx.dir, "plain")
      File.mkdir_p!(plain)
      {:ok, queued} = queue(ctx.card, "pwd")
      {_, 0} = run_once(ctx, lanes(ctx, plain))

      assert %{status: "done", output: output} = job(queued)
      assert output =~ "#{plain} is not a git repository, so no worktree"
      assert ctx.dir |> Path.join("out") |> File.read!() |> String.trim() == ctx.dir
    end

    test "a non-worktree directory in the worktree's place means the job is not run", ctx do
      repo = repo(ctx)
      File.mkdir_p!(lane_path(repo, ctx.card))
      {:ok, queued} = queue(ctx.card, "pwd")
      {out, 0} = run_once(ctx, lanes(ctx, repo))

      assert out =~ "no worktree for it"
      refute File.exists?(Path.join(ctx.dir, "out"))
      assert %{status: "failed", output: output} = job(queued)
      assert output =~ "is not a worktree, so the job was not run"
    end
  end

  describe "through a deploy" do
    alias SlipdockWeb.RunnerStubQueue, as: Stub

    # The runner looping, as it does for real, against a stub queue; it
    # stops at the stub's 401.
    defp run_against(ctx, answers) do
      {url, stub, server} = Stub.start(answers)
      on_exit(fn -> Process.exit(server, :normal) end)
      {out, 1} = run_loop(ctx, config(%{ctx | url: url}))
      {out, Stub.claims(stub)}
    end

    defp run_loop(ctx, config) do
      System.cmd("sh", [@script, "--config=#{config}"],
        cd: ctx.dir,
        env: [{"TMPDIR", ctx.dir}],
        stderr_to_stdout: true
      )
    end

    defp gaps(claims),
      do: claims |> Enum.chunk_every(2, 1, :discard) |> Enum.map(fn [a, b] -> b - a end)

    test "a claim the proxy lost is asked again a second later, without a word", ctx do
      {out, claims} = run_against(ctx, [{502, []}, {504, []}])

      assert length(claims) == 3
      refute out =~ "could not reach the queue"
      assert out =~ "the server refused this runner (HTTP 401)"
      assert Enum.all?(gaps(claims), &(&1 in 900..2_500))
    end

    test "gateway errors that go on are logged after the first three", ctx do
      {out, claims} = run_against(ctx, List.duplicate({502, []}, 4))

      assert length(claims) == 5
      assert [_] = Regex.scan(~r/could not reach the queue \(HTTP 502\)/, out)
    end

    test "other errors are logged at once, as before", ctx do
      {out, claims} = run_against(ctx, [{500, []}])

      assert length(claims) == 2
      assert out =~ "could not reach the queue (HTTP 500)"
    end

    test "a draining server's Retry-After is waited out before asking again", ctx do
      {out, claims} = run_against(ctx, [{204, [{"retry-after", "2"}]}, {204, []}])

      assert [drained, ordinary] = gaps(claims)
      assert drained >= 1_900
      assert ordinary < 900
      refute out =~ "could not reach the queue"
    end

    test "a Retry-After that isn't a number of seconds is ignored", ctx do
      {_out, claims} = run_against(ctx, [{204, [{"retry-after", "soon; rm -rf /"}]}])

      assert [gap] = gaps(claims)
      assert gap < 900
    end

    test "under --once a lost claim is still an error", ctx do
      {url, _stub, server} = Stub.start([{502, []}])
      on_exit(fn -> Process.exit(server, :normal) end)

      {out, 1} = run_once(ctx, config(%{ctx | url: url}))
      assert out =~ "could not reach the queue (HTTP 502)"
    end
  end

  describe "the live log (#1870)" do
    # Writes a transcript where Claude Code would: one line naming the card,
    # then a line every half second, a too-long one and some tokens.
    defp transcript_config(ctx, extra \\ "") do
      tx = Path.join([ctx.dir, "projects", "-work-app", "session.jsonl"])

      config(ctx, """
      TRANSCRIPTS='#{ctx.dir}/projects'
      TRANSCRIPT_EVERY=1
      TRANSCRIPT_LINE=200
      job_tx() {
        t='#{tx}'
        mkdir -p "${t%/*}"
        printf '{"n":0,"text":"%s"}\\n' "$SLIPDOCK_CARD_URL" >"$t"
        for i in 1 2 3 4 5 6; do printf '{"n":%s}\\n' "$i" >>"$t"; sleep 0.5; done
        printf '{"n":7,"text":"%s"}\\n' "$(printf 'x%.0s' $(seq 1 300))" >>"$t"
        printf '{"n":8,"text":"runner %s env %s saved %s"}\\n' "$SLIPDOCK_RUNNER_TOKEN" "$SLIPDOCK_TOKEN" "$(cat '#{ctx.dir}/cfg/slipdock/token')" >>"$t"
        printf '{"n":9,"partial":' >>"$t"
      }
      #{extra}
      """)
    end

    defp transcript_env(ctx) do
      File.mkdir_p!(Path.join(ctx.dir, "cfg/slipdock"))
      File.write!(Path.join(ctx.dir, "cfg/slipdock/token"), "abcdefghsaved0123456789\n")

      [
        {"SLIPDOCK_TOKEN", "abcdefghenv0123456789"},
        {"XDG_CONFIG_HOME", Path.join(ctx.dir, "cfg")}
      ]
    end

    defp transcript(job), do: job |> job() |> Slipdock.Runners.Transcript.read()

    test "sends the transcript while the job runs, and the rest as it ends", ctx do
      {:ok, queued} = queue(ctx.card, "tx")
      running = Task.async(fn -> run_once(ctx, transcript_config(ctx), transcript_env(ctx)) end)

      # Some of it is on the server before the job has ended.
      wait_for(fn ->
        j = job(queued)
        j.status == "running" and j.transcript_lines >= 2
      end)

      {_out, 0} = Task.await(running, 30_000)
      done = job(queued)
      assert done.status == "done"
      assert done.transcript_lines == 9
      assert done.output =~ "sending the transcript"

      lines = queued |> transcript() |> String.split("\n", trim: true)
      assert length(lines) == 9
      assert Enum.map(Enum.take(lines, 7), &Jason.decode!(&1)["n"]) == Enum.to_list(0..6)
      assert hd(lines) =~ "/cards/#{ctx.card.id}"

      # The long line was cut on this machine, and said so.
      assert Jason.decode!(Enum.at(lines, 7)) ==
               %{
                 "type" => "slipdock_cut",
                 "bytes" => byte_size(~s({"n":7,"text":""})) + 300,
                 "limit" => 200
               }

      # This machine's tokens never left it.
      last = List.last(lines)
      assert last =~ ~s("n":8)
      refute last =~ ctx.token
      refute last =~ "abcdefghenv0123456789"
      refute last =~ "abcdefghsaved0123456789"
      assert last =~ "runner [redacted] env [redacted] saved [redacted]"
      # A line still being written is not sent.
      refute transcript(queued) =~ "partial"
    end

    test "only a transcript written since the job started that names the card is sent", ctx do
      dir = Path.join([ctx.dir, "projects", "-elsewhere"])
      File.mkdir_p!(dir)
      old = Path.join(dir, "old.jsonl")
      File.write!(old, ~s({"old":"#{ctx.url}/boards/1/cards/#{ctx.card.id}"}\n))
      File.touch!(old, System.os_time(:second) - 600)

      extra = """
      job_other() {
        printf '{"other":"another session"}\\n' >'#{dir}/other.jsonl'
        sleep 2
      }
      """

      {:ok, queued} = queue(ctx.card, "other")
      {_out, 0} = run_once(ctx, transcript_config(ctx, extra), transcript_env(ctx))
      assert job(queued).status == "done"
      assert job(queued).transcript_lines == 0
      refute (job(queued).output || "") =~ "sending the transcript"
    end

    test "TRANSCRIPT_EVERY=0 sends nothing", ctx do
      {:ok, queued} = queue(ctx.card, "tx")

      {_out, 0} =
        run_once(ctx, transcript_config(ctx, "TRANSCRIPT_EVERY=0"), transcript_env(ctx))

      assert job(queued).status == "done"
      assert job(queued).transcript_lines == 0
    end

    test "sends that fail leave the job running, and the next one catches up", ctx do
      url = Flaky.start(fail: 4)
      {:ok, queued} = queue(ctx.card, "tx")

      {out, 0} =
        run_once(ctx, transcript_config(%{ctx | url: url}), transcript_env(ctx))

      assert out =~ "could not send the transcript (HTTP 503); trying again later", out
      assert Flaky.failed() == 4
      done = job(queued)
      assert {done.status, done.exit_code} == {"done", 0}
      assert done.transcript_lines == 9
      assert queued |> transcript() |> String.split("\n", trim: true) |> length() == 9
    end
  end
end
