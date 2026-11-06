defmodule SlipdockWeb.RunnerSelfUpdateTest do
  # Ship by PR 5 (#1658): the runner scripts say which script they are and,
  # with self-update on, replace an out-of-date copy of themselves between
  # jobs, and only on a matching checksum: after an empty claim, or after a
  # job's finish and before the next claim (#1925). Run for real (sh, and pwsh when
  # installed) against this app on a loopback port, on a copy of the script
  # made out of date by one extra line.
  use Slipdock.DataCase, async: false

  import Slipdock.Fixtures

  alias Slipdock.{Repo, Runners}
  alias Slipdock.Runners.{Job, Runner}
  alias SlipdockWeb.RunnerInstallController

  @pwsh System.get_env("SLIPDOCK_PWSH") || System.find_executable("pwsh")

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

    dir = Path.join(System.tmp_dir!(), "slipdock-update-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    board = board_fixture()
    card = card_fixture(hd(board.columns), %{"title" => "Run me"})
    {:ok, runner, token} = Runners.create_runner(board, %{"name" => "up", "pool" => "dev"})

    %{
      url: "http://127.0.0.1:#{port}",
      dir: dir,
      card: card,
      column: hd(board.columns),
      runner: runner,
      token: token
    }
  end

  defp sha(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  # An out-of-date copy: the served script with one more line.
  defp old_copy(ctx, name) do
    path = Path.join(ctx.dir, name)
    File.write!(path, RunnerInstallController.files()[name] <> "# an older release\n")
    File.chmod!(path, 0o755)
    path
  end

  # A stand-in for the server's files, as file:// (SELF_UPDATE_URL), with
  # SHA256SUMS naming something else than what is there.
  defp bad_mirror(ctx, name) do
    mirror = Path.join(ctx.dir, "mirror")
    File.mkdir_p!(mirror)
    File.write!(Path.join(mirror, name), RunnerInstallController.files()[name])
    File.write!(Path.join(mirror, "SHA256SUMS"), String.duplicate("b", 64) <> "  #{name}\n")
    "file://" <> mirror
  end

  defp queue_two(ctx) do
    for title <- ["Pass one", "Pass two"] do
      card = card_fixture(ctx.column, %{"title" => title})
      {:ok, job} = Runners.queue(card, %{pool: "dev", kind: "mark", prompt: "go"})
      job
    end
  end

  defp marker(ctx, job), do: Path.join(ctx.dir, "job-#{job.id}")

  defp assert_in_order(out, needles) do
    Enum.reduce(needles, 0, fn needle, from ->
      rest = binary_part(out, from, byte_size(out) - from)

      case :binary.match(rest, needle) do
        {at, len} -> from + at + len
        :nomatch -> flunk("#{inspect(needle)} not found in order in:\n#{out}")
      end
    end)
  end

  # Runs `cmd` under a deadline until every one of `jobs` is done (or the
  # deadline passes), then revokes the runner's token: its next claim is
  # refused, and it exits. Answers what it said and how it exited.
  defp runner(ctx, [cmd | args], jobs, opts) do
    task =
      Task.async(fn ->
        System.cmd("timeout", ["-k", "5", "45", cmd | args], [stderr_to_stdout: true] ++ opts)
      end)

    wait_done(jobs, System.monotonic_time(:millisecond) + 45_000)
    Repo.delete!(Repo.get!(Runner, ctx.runner.id))
    Task.await(task, 55_000)
  end

  defp wait_done(jobs, deadline) do
    done? = Enum.all?(jobs, &(Repo.get!(Job, &1.id).status in ~w(done failed)))

    if not done? and System.monotonic_time(:millisecond) < deadline do
      Process.sleep(100)
      wait_done(jobs, deadline)
    end
  end

  describe "the shell runner" do
    defp config(ctx, extra) do
      path = Path.join(ctx.dir, "config")

      File.write!(path, """
      SLIPDOCK_URL='#{ctx.url}'
      SLIPDOCK_RUNNER_TOKEN='#{ctx.token}'
      WAIT=0
      HEARTBEAT=1
      job_echo() { echo hi; }
      #{extra}
      """)

      path
    end

    defp run(ctx, script, config) do
      System.cmd("sh", [script, "--once", "--config=#{config}"],
        cd: ctx.dir,
        env: [{"TMPDIR", ctx.dir}],
        stderr_to_stdout: true
      )
    end

    test "says which script it is on every claim", ctx do
      script = old_copy(ctx, "slipdock-runner")
      {_out, 0} = run(ctx, script, config(ctx, ""))

      assert Repo.get!(Runner, ctx.runner.id).version == "sh " <> sha(File.read!(script))
    end

    test "with SELF_UPDATE=1 and nothing to do, replaces itself with the served script", ctx do
      script = old_copy(ctx, "slipdock-runner")
      {out, 0} = run(ctx, script, config(ctx, "SELF_UPDATE=1"))

      assert out =~ "self-update: replaced #{script}"
      assert File.read!(script) == RunnerInstallController.files()["slipdock-runner"]
      assert File.stat!(script).mode |> Bitwise.band(0o111) != 0
    end

    test "a checksum that doesn't match keeps the script as it is", ctx do
      script = old_copy(ctx, "slipdock-runner")
      before = File.read!(script)
      mirror = bad_mirror(ctx, "slipdock-runner")
      {out, 0} = run(ctx, script, config(ctx, "SELF_UPDATE=1\nSELF_UPDATE_URL='#{mirror}'"))

      assert out =~ "self-update: checksum mismatch"
      assert File.read!(script) == before
    end

    test "off by default: an out-of-date script stays", ctx do
      script = old_copy(ctx, "slipdock-runner")
      before = File.read!(script)
      {out, 0} = run(ctx, script, config(ctx, ""))

      refute out =~ "self-update"
      assert File.read!(script) == before
    end

    # Two jobs queued back to back, as the board does with an epic it sends
    # again a second after each pass (#1925): the queue never comes back
    # empty, so only an update between jobs can reach this runner.
    test "after a job's finish and before the next claim, an old script replaces itself", ctx do
      [first, second] = queue_two(ctx)
      script = old_copy(ctx, "slipdock-runner")
      old_sha = sha(File.read!(script))
      {out, _} = run_until(ctx, script, sh_config_marking(ctx, "SELF_UPDATE=1"), [first, second])

      assert Repo.get!(Job, first.id).status == "done"
      assert Repo.get!(Job, second.id).status == "done"
      assert File.read!(script) == RunnerInstallController.files()["slipdock-runner"]

      # The first job ran on the old script, the second on the new one, and
      # the update came between the first job's finish and the second's claim.
      assert File.read!(marker(ctx, first)) == old_sha
      assert File.read!(marker(ctx, second)) == RunnerInstallController.latest()["sh"]

      assert_in_order(out, [
        "job ##{first.id}: exit 0",
        "self-update: replaced",
        "job ##{second.id}:"
      ])
    end

    test "--once with a job: the update follows the job's finish, then it exits", ctx do
      {:ok, queued} = Runners.queue(ctx.card, %{pool: "dev", kind: "echo", prompt: "go"})
      script = old_copy(ctx, "slipdock-runner")
      {out, 0} = run(ctx, script, config(ctx, "SELF_UPDATE=1"))

      assert Repo.get!(Job, queued.id).status == "done"
      assert File.read!(script) == RunnerInstallController.files()["slipdock-runner"]
      assert_in_order(out, ["job ##{queued.id}: exit 0", "self-update: replaced"])
    end

    test "without SELF_UPDATE, back-to-back jobs both run on the old script", ctx do
      [first, second] = queue_two(ctx)
      script = old_copy(ctx, "slipdock-runner")
      before = File.read!(script)
      {out, _} = run_until(ctx, script, sh_config_marking(ctx, ""), [first, second])

      assert Repo.get!(Job, second.id).status == "done"
      refute out =~ "self-update"
      assert File.read!(script) == before
      assert File.read!(marker(ctx, second)) == sha(before)
    end

    test "a failed fetch after a job keeps the script, and it takes the next job", ctx do
      [first, second] = queue_two(ctx)
      script = old_copy(ctx, "slipdock-runner")
      before = File.read!(script)
      gone = "file://" <> Path.join(ctx.dir, "no-such-mirror")
      extra = "SELF_UPDATE=1\nSELF_UPDATE_URL='#{gone}'"
      {out, _} = run_until(ctx, script, sh_config_marking(ctx, extra), [first, second])

      assert Repo.get!(Job, second.id).status == "done"
      assert File.read!(script) == before
      assert File.read!(marker(ctx, second)) == sha(before)
      # Tried once for that version, not again after every job.
      assert length(String.split(out, "self-update: could not fetch")) == 2
    end

    test "a checksum mismatch after a job keeps the script, and it takes the next job", ctx do
      [first, second] = queue_two(ctx)
      script = old_copy(ctx, "slipdock-runner")
      before = File.read!(script)
      mirror = bad_mirror(ctx, "slipdock-runner")
      extra = "SELF_UPDATE=1\nSELF_UPDATE_URL='#{mirror}'"
      {out, _} = run_until(ctx, script, sh_config_marking(ctx, extra), [first, second])

      assert Repo.get!(Job, second.id).status == "done"
      assert out =~ "self-update: checksum mismatch"
      assert File.read!(script) == before
      assert File.read!(marker(ctx, second)) == sha(before)
    end

    # A config whose job writes the SHA-256 of the script running it.
    defp sh_config_marking(ctx, extra) do
      config(ctx, """
      job_mark() { printf '%s' "$MY_SHA" >'#{ctx.dir}/job-'"$SLIPDOCK_JOB_ID"; }
      #{extra}
      """)
    end

    # The runner, not --once, until every one of `jobs` is done; then its
    # token is revoked, which stops it (and whatever script it is by then).
    defp run_until(ctx, script, config, jobs) do
      runner(ctx, ["sh", script, "--config=#{config}"], jobs,
        cd: ctx.dir,
        env: [{"TMPDIR", ctx.dir}]
      )
    end

    test "a current script doesn't fetch anything", ctx do
      script = Path.join(ctx.dir, "slipdock-runner")
      File.write!(script, RunnerInstallController.files()["slipdock-runner"])
      {out, 0} = run(ctx, script, config(ctx, "SELF_UPDATE=1"))

      refute out =~ "self-update"

      assert Repo.get!(Runner, ctx.runner.id).version ==
               "sh " <> RunnerInstallController.latest()["sh"]
    end
  end

  describe "the PowerShell runner" do
    if is_nil(@pwsh),
      do: @describetag(skip: "pwsh (PowerShell) is not installed here; CI runs these")

    defp ps_config(ctx, extra) do
      path = Path.join(ctx.dir, "config.ps1")

      File.write!(path, """
      $SlipdockUrl = '#{ctx.url}'
      $RunnerToken = '#{ctx.token}'
      $Pool = 'dev'
      $Wait = 0
      $Heartbeat = 1
      function Job-Echo { Write-Output 'hi' }
      function Job-Mark { Write-Output 'marked' }
      #{extra}
      """)

      path
    end

    # Under a deadline inside ExUnit's 60 s (#1854): a runner that hangs is
    # stopped, and the test fails on its exit (124) with what it said by then.
    defp ps_run(ctx, script, config) do
      System.cmd(
        "timeout",
        ["-k", "5", "40", @pwsh, "-NoProfile", "-File", script, "-Once", "-Config", config],
        cd: ctx.dir,
        stderr_to_stdout: true
      )
    end

    test "says which script it is, replaces an old copy, and keeps it on a bad checksum", ctx do
      script = old_copy(ctx, "slipdock-runner.ps1")
      old_sha = sha(File.read!(script))

      # Off: says its version, stays.
      {_out, 0} = ps_run(ctx, script, ps_config(ctx, ""))
      assert Repo.get!(Runner, ctx.runner.id).version == "ps1 " <> old_sha
      assert sha(File.read!(script)) == old_sha

      # A bad checksum: stays.
      mirror = bad_mirror(ctx, "slipdock-runner.ps1")

      {out, 0} =
        ps_run(ctx, script, ps_config(ctx, "$SelfUpdate = $true\n$SelfUpdateUrl = '#{mirror}'"))

      assert out =~ "self-update: checksum mismatch"
      assert sha(File.read!(script)) == old_sha

      # On, from the server: replaced with the served script.
      {out, 0} = ps_run(ctx, script, ps_config(ctx, "$SelfUpdate = $true"))
      assert out =~ "self-update: replaced"
      assert File.read!(script) == RunnerInstallController.files()["slipdock-runner.ps1"]
    end

    test "back-to-back jobs: replaced after the first job's finish, the second on the new script",
         ctx do
      [first, second] = queue_two(ctx)
      script = old_copy(ctx, "slipdock-runner.ps1")
      {out, _} = ps_run_until(ctx, script, ps_config(ctx, "$SelfUpdate = $true"), [first, second])

      assert Repo.get!(Job, first.id).status == "done"
      assert Repo.get!(Job, second.id).status == "done"
      assert File.read!(script) == RunnerInstallController.files()["slipdock-runner.ps1"]
      assert_in_order(out, ["job ##{first.id}", "self-update: replaced", "job ##{second.id}"])
    end

    test "back-to-back jobs on a bad checksum: kept, and the next job still runs", ctx do
      [first, second] = queue_two(ctx)
      script = old_copy(ctx, "slipdock-runner.ps1")
      before = File.read!(script)
      mirror = bad_mirror(ctx, "slipdock-runner.ps1")
      config = ps_config(ctx, "$SelfUpdate = $true\n$SelfUpdateUrl = '#{mirror}'")
      {out, _} = ps_run_until(ctx, script, config, [first, second])

      assert Repo.get!(Job, second.id).status == "done"

      assert_in_order(out, [
        "job ##{first.id}",
        "self-update: checksum mismatch",
        "job ##{second.id}"
      ])

      assert File.read!(script) == before
    end

    defp ps_run_until(ctx, script, config, jobs) do
      runner(ctx, [@pwsh, "-NoProfile", "-File", script, "-Config", config], jobs, cd: ctx.dir)
    end

    test "CRLF line endings, as Windows may write them, still read as current", ctx do
      script = Path.join(ctx.dir, "slipdock-runner.ps1")

      File.write!(
        script,
        String.replace(RunnerInstallController.files()["slipdock-runner.ps1"], "\n", "\r\n")
      )

      {out, 0} = ps_run(ctx, script, ps_config(ctx, "$SelfUpdate = $true"))
      refute out =~ "self-update"

      assert Repo.get!(Runner, ctx.runner.id).version ==
               "ps1 " <> RunnerInstallController.latest()["ps1"]
    end
  end
end
