defmodule SlipdockWeb.RunnerPowerShellTest do
  # The PowerShell runner (`priv/runner/slipdock-runner.ps1`) and its
  # installer, run for real under `pwsh` against this app on a loopback port —
  # when PowerShell is installed. GitHub's Ubuntu runners have it; a machine
  # without it skips these with the reason. `SLIPDOCK_PWSH` names another one.
  #
  # Windows-only parts (Task Scheduler, the ACL, taskkill) can't run here; the
  # installer's -NoStart and the runner's non-Windows tree kill stand in.
  use Slipdock.DataCase, async: false

  import Slipdock.Fixtures

  alias Slipdock.{Repo, Runners}
  alias Slipdock.Runners.Job

  @script Path.expand("../../priv/runner/slipdock-runner.ps1", __DIR__)
  @pwsh System.get_env("SLIPDOCK_PWSH") || System.find_executable("pwsh")

  if is_nil(@pwsh) do
    @moduletag skip: "pwsh (PowerShell) is not installed here; CI runs these"
  end

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

    dir = Path.join(System.tmp_dir!(), "slipdock-ps-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    board = board_fixture()
    card = card_fixture(hd(board.columns), %{"title" => "Run me"})
    {:ok, runner, token} = Runners.create_runner(board, %{"name" => "ps", "pool" => "dev"})

    %{url: "http://127.0.0.1:#{port}", dir: dir, card: card, runner: runner, token: token}
  end

  defp config(ctx, extra \\ "") do
    path = Path.join(ctx.dir, "config.ps1")

    File.write!(path, """
    $SlipdockUrl = '#{ctx.url}'
    $RunnerToken = '#{ctx.token}'
    $Pool = 'dev'
    $Wait = 0
    $Heartbeat = 1
    $JobTimeout = 30
    function Job-Echo { [IO.File]::WriteAllText('#{ctx.dir}/out', $env:SLIPDOCK_PROMPT); Write-Output "card $env:SLIPDOCK_CARD job $env:SLIPDOCK_JOB_ID" }
    function Job-Fail { Write-Output 'about to fail'; exit 3 }
    function Job-Sleep { Write-Output 'started'; $p = Start-Process -FilePath sleep -ArgumentList 60 -PassThru; Set-Content -Path '#{ctx.dir}/child' -Value $p.Id; $p.WaitForExit(); Write-Output 'never' }
    function Job-TwoWords { Write-Output 'dashed' }
    function After-Job { Add-Content -Path '#{ctx.dir}/after' -Value "$env:SLIPDOCK_STATUS $env:SLIPDOCK_EXIT" }
    #{extra}
    """)

    path
  end

  defp run_once(ctx, config) do
    System.cmd(@pwsh, ["-NoProfile", "-File", @script, "-Once", "-Config", config],
      cd: ctx.dir,
      stderr_to_stdout: true
    )
  end

  defp queue(card, kind, prompt \\ "go"),
    do: Runners.queue(card, %{pool: "dev", kind: kind, prompt: prompt})

  defp job(job), do: Repo.get!(Job, job.id)

  defp after_lines(ctx),
    do: ctx.dir |> Path.join("after") |> File.read!() |> String.split(~r/\R/, trim: true)

  defp alive?(pid), do: match?({_, 0}, System.cmd("kill", ["-0", pid], stderr_to_stdout: true))

  defp wait_for(fun, tries \\ 150) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("timed out waiting")
      true -> Process.sleep(100) && wait_for(fun, tries - 1)
    end
  end

  test "takes a job, runs its kind with the card in the environment, and finishes it", ctx do
    prompt = ~S{Fix "it" — $(touch PWNED) `touch PWNED` $env:HOME 'quoted' café}
    {:ok, queued} = queue(ctx.card, "echo", prompt)
    {out, 0} = run_once(ctx, config(ctx))

    assert out =~ "job ##{queued.id}: echo for card ##{ctx.card.id}"
    assert File.read!(Path.join(ctx.dir, "out")) == prompt
    assert Path.wildcard(Path.join(ctx.dir, "PWNED*")) == []

    done = job(queued)
    assert {done.status, done.exit_code} == {"done", 0}
    assert done.output =~ "card #{ctx.card.id} job #{queued.id}"
    assert after_lines(ctx) == ["done 0"]
  end

  test "with nothing queued, -Once asks once and leaves — $Wait = 0 meaning no wait", ctx do
    started = System.monotonic_time(:millisecond)
    assert {_out, 0} = run_once(ctx, config(ctx))
    assert System.monotonic_time(:millisecond) - started < 15_000
  end

  test "an unknown kind is refused with 127 and nothing runs", ctx do
    {:ok, queued} = queue(ctx.card, "evil")
    {out, 0} = run_once(ctx, config(ctx))
    assert out =~ "no Job-Evil"
    assert %{status: "failed", exit_code: 127} = job(queued)
  end

  test "a kind with a dash is the PascalCase function", ctx do
    {:ok, queued} = queue(ctx.card, "two-words")
    {_out, 0} = run_once(ctx, config(ctx))
    assert %{status: "done"} = done = job(queued)
    assert done.output =~ "dashed"
  end

  test "a failing job is failed with its exit code, and After-Job hears so", ctx do
    {:ok, queued} = queue(ctx.card, "fail")
    {_out, 0} = run_once(ctx, config(ctx))
    assert %{status: "failed", exit_code: 3} = failed = job(queued)
    assert failed.output =~ "about to fail"
    assert after_lines(ctx) == ["failed 3"]
  end

  test "a job over its time is stopped, children and all", ctx do
    {:ok, queued} = queue(ctx.card, "sleep")
    {out, 0} = run_once(ctx, config(ctx, "$JobTimeout = 3"))
    assert out =~ "over its 3s"
    assert %{status: "timeout", exit_code: 124} = job(queued)
    refute alive?(ctx.dir |> Path.join("child") |> File.read!() |> String.trim())
    assert after_lines(ctx) == ["timeout 124"]
  end

  test "a job cancelled from the board is stopped on the next heartbeat", ctx do
    {:ok, queued} = queue(ctx.card, "sleep")
    cfg = config(ctx)
    running = Task.async(fn -> run_once(ctx, cfg) end)
    wait_for(fn -> job(queued).status == "running" end)
    {:ok, _} = Runners.cancel_job(job(queued))

    {out, 0} = Task.await(running, 30_000)
    assert out =~ "cancelled from the board"
    assert %{status: "cancelled", exit_code: 130} = job(queued)
    refute alive?(ctx.dir |> Path.join("child") |> File.read!() |> String.trim())
  end

  test "a Before-Job that fails means the job never runs", ctx do
    {:ok, queued} = queue(ctx.card, "echo")
    {out, 0} = run_once(ctx, config(ctx, "function Before-Job { throw 'not today' }"))
    assert out =~ "Before-Job failed"
    refute File.exists?(Path.join(ctx.dir, "out"))
    assert %{status: "failed"} = job(queued)
    assert after_lines(ctx) == ["failed 1"]
  end

  test "standing instructions are added after the prompt", ctx do
    {:ok, queued} = queue(ctx.card, "echo", "The card.")
    {_out, 0} = run_once(ctx, config(ctx, "$JobInstructions = 'Be brief.'"))
    assert job(queued).status == "done"
    assert File.read!(Path.join(ctx.dir, "out")) == "The card.\n\nBe brief."
  end

  test "a revoked token stops the runner with the reason", ctx do
    {:ok, _} = Runners.delete_runner(ctx.runner)
    {out, 1} = run_once(ctx, config(ctx))
    assert out =~ "refused this runner (HTTP 401)"
  end

  describe "install.ps1" do
    defp install(ctx, args) do
      installer = Path.join(ctx.dir, "install.ps1")
      File.write!(installer, SlipdockWeb.RunnerInstallController.files()["install.ps1"])

      System.cmd(
        @pwsh,
        [
          "-NoProfile",
          "-File",
          installer,
          "-InstallDir",
          Path.join(ctx.dir, "inst"),
          "-NoStart" | args
        ],
        stderr_to_stdout: true
      )
    end

    defp installed(ctx, var) do
      cfg = Path.join([ctx.dir, "inst", "config.ps1"])

      {out, 0} =
        System.cmd(@pwsh, ["-NoProfile", "-Command", ". '#{cfg}'; [Console]::Out.Write($#{var})"])

      out
    end

    test "writes the runner and a config that keeps every value exactly", ctx do
      instructions = "Don't \"push\".\n'@ at the start of a line\n@' too — café $(nope)"

      {out, 0} =
        install(ctx, [
          "-Url",
          ctx.url,
          "-Token",
          "sdr_it's",
          "-Pool",
          "dev",
          "-Agent",
          "custom",
          "-Command",
          "Write-Output 'hi'",
          "-Cwd",
          "C:\\src\\it's",
          "-Timeout",
          "900",
          "-Instructions",
          instructions,
          "-AfterJob",
          "Write-Output \"after $env:SLIPDOCK_STATUS\""
        ])

      assert out =~ "installed"
      runner = Path.join([ctx.dir, "inst", "slipdock-runner.ps1"])

      assert File.read!(runner) ==
               SlipdockWeb.RunnerInstallController.files()["slipdock-runner.ps1"]

      assert installed(ctx, "SlipdockUrl") == ctx.url
      assert installed(ctx, "RunnerToken") == "sdr_it's"
      assert installed(ctx, "WorkDir") == "C:\\src\\it's"
      assert installed(ctx, "JobTimeout") == "900"
      assert installed(ctx, "CustomCommand") == "Write-Output 'hi'"
      assert installed(ctx, "JobInstructions") == instructions

      config = File.read!(Path.join([ctx.dir, "inst", "config.ps1"]))
      assert config =~ "function Job-Custom"
      assert config =~ "function After-Job"
    end

    test "plain instructions go in a literal here-string", ctx do
      {_, 0} = install(ctx, ["-Url", ctx.url, "-Token", "t", "-Instructions", "Be brief. $(x)"])

      assert File.read!(Path.join([ctx.dir, "inst", "config.ps1"])) =~
               "$JobInstructions = @'\nBe brief. $(x)\n'@"

      assert installed(ctx, "JobInstructions") == "Be brief. $(x)"
    end

    test "installing again keeps the token, and the old config beside the new", ctx do
      {_, 0} = install(ctx, ["-Url", ctx.url, "-Token", "sdr_first"])
      {_, 0} = install(ctx, ["-Url", ctx.url, "-Timeout", "120"])
      assert installed(ctx, "RunnerToken") == "sdr_first"
      assert installed(ctx, "JobTimeout") == "120"
      assert [_] = Path.wildcard(Path.join([ctx.dir, "inst", "config.ps1.bak.*"]))
    end

    test "refuses what it can't use", ctx do
      {out, code} = install(ctx, ["-Token", "t"])
      assert code != 0
      assert out =~ "-Url is required"

      {out, code} = install(ctx, ["-Url", ctx.url, "-Token", "t", "-Pool", "Bad Pool"])
      assert code != 0
      assert out =~ "-Pool must be"
    end

    test "what it installs takes and runs a job", ctx do
      {_, 0} =
        install(ctx, [
          "-Url",
          ctx.url,
          "-Token",
          ctx.token,
          "-Pool",
          "dev",
          "-Agent",
          "custom",
          "-Command",
          "Write-Output \"ran: $env:SLIPDOCK_PROMPT\"",
          "-Cwd",
          ctx.dir
        ])

      {:ok, queued} = queue(ctx.card, "custom", "the card")

      {_out, 0} =
        System.cmd(
          @pwsh,
          [
            "-NoProfile",
            "-File",
            Path.join([ctx.dir, "inst", "slipdock-runner.ps1"]),
            "-Once",
            "-Config",
            Path.join([ctx.dir, "inst", "config.ps1"])
          ],
          stderr_to_stdout: true
        )

      assert %{status: "done"} = done = job(queued)
      assert done.output =~ "ran: the card"
    end
  end

  test "the wizard's Windows one-liner runs as written", ctx do
    {:ok, a} =
      Slipdock.Runners.Setup.normalise(%{
        "scenario" => "windows",
        "pool" => "dev",
        "agent" => "custom",
        "kind" => "my-agent",
        "command" => "Write-Output 'hi'",
        "cwd" => ctx.dir,
        "timeout" => "600",
        "instructions" => "Don't push. '@ here",
        "after_job" => "Write-Output 'after'"
      })

    line = Slipdock.Runners.Setup.windows_one_liner(a, %{base_url: ctx.url, token: "sdr_t'ok"})
    installer = Path.join(ctx.dir, "install.ps1")
    File.write!(installer, SlipdockWeb.RunnerInstallController.files()["install.ps1"])

    # The download, swapped for the file; and kept out of the real profile.
    command =
      String.replace(line, ~r/\(irm '[^']+'\)/, "(Get-Content -Raw '#{installer}')") <>
        " `\n  -InstallDir '#{ctx.dir}/inst' -NoStart"

    {out, 0} = System.cmd(@pwsh, ["-NoProfile", "-Command", command], stderr_to_stdout: true)
    assert out =~ "installed"

    cfg = Path.join([ctx.dir, "inst", "config.ps1"])
    config = File.read!(cfg)
    assert config =~ "function Job-MyAgent"
    assert config =~ "function After-Job"

    {token, 0} =
      System.cmd(@pwsh, [
        "-NoProfile",
        "-Command",
        ". '#{cfg}'; [Console]::Out.Write($RunnerToken + '|' + $JobInstructions + '|' + $JobTimeout)"
      ])

    assert token == "sdr_t'ok|Don't push. '@ here|600"
  end
end
