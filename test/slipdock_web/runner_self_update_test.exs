defmodule SlipdockWeb.RunnerSelfUpdateTest do
  # Ship by PR 5 (#1658): the runner scripts say which script they are and,
  # with self-update on, replace an out-of-date copy of themselves between
  # jobs, and only on a matching checksum. Run for real (sh, and pwsh when
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

    %{url: "http://127.0.0.1:#{port}", dir: dir, card: card, runner: runner, token: token}
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

    test "never after taking a job: only an empty claim updates", ctx do
      {:ok, queued} = Runners.queue(ctx.card, %{pool: "dev", kind: "echo", prompt: "go"})
      script = old_copy(ctx, "slipdock-runner")
      before = File.read!(script)
      {out, 0} = run(ctx, script, config(ctx, "SELF_UPDATE=1"))

      assert Repo.get!(Job, queued.id).status == "done"
      refute out =~ "self-update"
      assert File.read!(script) == before
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
