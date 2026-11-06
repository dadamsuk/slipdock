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

  # Under a deadline well inside ExUnit's 60 s (#1854): a runner that hangs
  # is stopped, and the test fails on its exit (124) with everything it said,
  # rather than timing out inside System.cmd with nothing to go on.
  defp run_once(ctx, config, deadline \\ 40) do
    System.cmd(
      "timeout",
      [
        "-k",
        "5",
        "#{deadline}",
        @pwsh,
        "-NoProfile",
        "-File",
        @script,
        "-Once",
        "-Config",
        config
      ],
      cd: ctx.dir,
      stderr_to_stdout: true
    )
  end

  # Each claim the server answers, as {query string, status, milliseconds}.
  defp record_claims do
    test = self()
    id = "claims-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        id,
        [:phoenix, :endpoint, :stop],
        fn _event, %{duration: duration}, %{conn: conn}, _ ->
          if conn.request_path == "/api/runner/claim" do
            ms = System.convert_time_unit(duration, :native, :millisecond)
            send(test, {:claim, conn.query_string, conn.status, ms})
          end
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(id) end)
    fn -> collect_claims([]) end
  end

  defp collect_claims(acc) do
    receive do
      {:claim, query, status, ms} -> collect_claims([{query, status, ms} | acc])
    after
      0 -> Enum.reverse(acc)
    end
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

  # Timed on the server, not by the clock around the run (#1915): pwsh alone
  # can take 15 s to start on a loaded CI machine. $Wait = 0 read as falsy
  # would ask for the 25 s default, and the server would hold the claim open.
  test "with nothing queued, -Once asks once and leaves — $Wait = 0 meaning no wait", ctx do
    claims = record_claims()
    assert {_out, 0} = run_once(ctx, config(ctx))

    assert [{query, 204, ms}] = claims.()
    assert URI.decode_query(query)["wait"] == "0"
    assert ms < 5_000
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

  # pwsh can take well over 15s to start on a loaded CI machine (#483), so
  # this waits for the job's own child pid file rather than a fixed slice of
  # polling, with a test timeout to match.
  @tag timeout: 180_000
  test "a job cancelled from the board is stopped on the next heartbeat", ctx do
    {:ok, queued} = queue(ctx.card, "sleep")
    cfg = config(ctx)
    child_file = Path.join(ctx.dir, "child")
    running = Task.async(fn -> run_once(ctx, cfg, 150) end)
    wait_for(fn -> File.exists?(child_file) and job(queued).status == "running" end, 900)
    {:ok, _} = Runners.cancel_job(job(queued))

    {out, 0} = Task.await(running, 160_000)
    assert out =~ "cancelled from the board"
    assert %{status: "cancelled", exit_code: 130} = job(queued)
    refute alive?(child_file |> File.read!() |> String.trim())
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

  # #1481: Windows PowerShell holds the job's out and err open without read
  # sharing, and the heartbeat's ReadAllText failed on them and stopped the
  # runner. Linux doesn't lock those the same way, so the job here locks the
  # runner's `log` beside them, exclusively, across a few heartbeats: the
  # heartbeats carry on without it, and the job finishes with all of it.
  #
  # .NET on Linux makes FileShare.None an exclusive flock, and the
  # heartbeat's read of the log holds a shared one while it reads. So the
  # job's open fails if it lands on a heartbeat (more often on a loaded
  # machine, #1854): it tries again until the lock is its own.
  test "a log file the runner can't open for a heartbeat doesn't stop it", ctx do
    {:ok, queued} = queue(ctx.card, "hold")

    hold = ~S"""
    function Job-Hold {
      $runner = (Get-Process -Id $PID).Parent.Id
      $out = Get-ChildItem "/proc/$runner/fd" | ForEach-Object { & readlink $_.FullName } |
        Where-Object { $_ -like '*slipdock-runner-*/out' } | Select-Object -First 1
      $log = Join-Path (Split-Path -Parent $out) 'log'
      $fs = $null
      for ($try = 1; -not $fs; $try++) {
        try { $fs = [IO.File]::Open($log, 'Open', 'ReadWrite', 'None') } catch {
          if ($try -ge 200) { throw }
          Start-Sleep -Milliseconds 25
        }
      }
      Write-Output 'holding the log'
      Start-Sleep -Seconds 4
      $fs.Dispose()
      Write-Output 'let go'
    }
    """

    {out, 0} = run_once(ctx, config(ctx, hold))
    refute out =~ "failed"

    done = job(queued)

    assert {done.status, done.exit_code} == {"done", 0},
           out <> "\n--- job output:\n" <> done.output

    assert done.output =~ "holding the log"
    assert done.output =~ "let go"
    assert after_lines(ctx) == ["done 0"]
  end

  # #1854: PowerShell 7.4's -TimeoutSec only bounds the wait for headers. A
  # server that sends them and stalls in the body held the runner until it
  # hung up; the read has a time limit of its own now, so the claim gives
  # up after its 15 s like any unanswered one.
  @tag timeout: 90_000
  test "a server that stalls partway through an answer is given up on", ctx do
    stall = stalling_server()
    started = System.monotonic_time(:millisecond)
    {out, 1} = run_once(%{ctx | url: stall}, config(%{ctx | url: stall}), 60)

    assert out =~ "could not reach the queue (HTTP 0)"
    assert System.monotonic_time(:millisecond) - started < 50_000
  end

  # Answers every request with headers for a 100-byte body, sends two bytes
  # of it, and then nothing more until the test is over.
  defp stalling_server do
    test = self()

    start_supervised!(
      {Task,
       fn ->
         {:ok, listen} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}, active: false])
         {:ok, port} = :inet.port(listen)
         send(test, {:stalling, port})
         stall(listen)
       end}
    )

    assert_receive {:stalling, port}
    "http://127.0.0.1:#{port}"
  end

  defp stall(listen) do
    {:ok, socket} = :gen_tcp.accept(listen)
    {:ok, _request} = :gen_tcp.recv(socket, 0)

    :ok =
      :gen_tcp.send(
        socket,
        "HTTP/1.1 200 OK\r\ncontent-type: text/plain\r\ncontent-length: 100\r\n\r\nab"
      )

    stall(listen)
  end

  test "an error while a job runs is logged, and the job stopped and failed", ctx do
    {:ok, queued} = queue(ctx.card, "sleep")
    # A Before-Job that breaks the heartbeat sum: the error comes once the
    # job's process is running, where the runner used to die and leave it.
    {out, 0} = run_once(ctx, config(ctx, "function Before-Job { $script:Heartbeat = 'x' }"))

    assert out =~ "job ##{queued.id}: the runner failed while running it"
    assert File.read!(Path.join(ctx.dir, "runner.log")) =~ "the runner failed while running it"

    failed = job(queued)
    assert {failed.status, failed.exit_code} == {"failed", 1}
    assert failed.output =~ "slipdock-runner: failed while running the job"
    assert after_lines(ctx) == ["failed 1"]

    child = Path.join(ctx.dir, "child")
    if File.exists?(child), do: refute(alive?(child |> File.read!() |> String.trim()))
  end

  test "an error outside a job goes in the runner's log, not only to stderr", ctx do
    {out, 1} = run_once(ctx, config(ctx, "$Wait = 'x'"))
    assert out =~ "runner error:"
    assert File.read!(Path.join(ctx.dir, "runner.log")) =~ "runner error:"
  end

  # CI runs this one on Windows PowerShell 5.1 as well (the windows-runner
  # job); here it keeps the script itself working.
  test "the Windows smoke script passes under pwsh, and fails on a runner that dies", ctx do
    smoke = Path.expand("../powershell/runner_smoke.ps1", __DIR__)

    {out, 0} = System.cmd(@pwsh, ["-NoProfile", "-File", smoke], stderr_to_stdout: true)
    assert out =~ ~r/ok: \d+ heartbeats, finished with \?exit=0/

    dead = Path.join(ctx.dir, "dead.ps1")

    File.write!(
      dead,
      ~S{param($Config, [switch]$Once) [Console]::Error.WriteLine('boom'); exit 1}
    )

    {out, 1} =
      System.cmd(@pwsh, ["-NoProfile", "-File", smoke, "-Runner", dead], stderr_to_stdout: true)

    assert out =~ "boom"
    assert out =~ "FAIL: the job was never finished"
  end

  describe "worktrees (lanes)" do
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
      $Worktree = $true
      $WorktreeRepo = '#{repo}'
      function Job-Pwd { [IO.File]::WriteAllText('#{ctx.dir}/out', (Get-Location).Path); Write-Output "wt=$env:SLIPDOCK_WORKTREE" }
      function Job-Dirty { [IO.File]::WriteAllText('#{ctx.dir}/out', (Get-Location).Path); Set-Content -Path scratch.txt -Value scratch }
      function Before-Job { [IO.File]::WriteAllText('#{ctx.dir}/before', (Get-Location).Path) }
      #{extra}
      """)
    end

    defp lane_path(repo, card), do: "#{repo}-lanes/card-#{card.id}"
    defp read(ctx, name), do: ctx.dir |> Path.join(name) |> File.read!() |> String.trim()

    test "on: the job and Before-Job run in a worktree on the card's branch, removed after",
         ctx do
      repo = repo(ctx)
      {:ok, queued} = queue(ctx.card, "pwd")
      {_, 0} = run_once(ctx, lanes(ctx, repo))

      path = lane_path(repo, ctx.card)
      assert read(ctx, "out") == path
      assert read(ctx, "before") == path

      assert %{status: "done", output: output} = job(queued)
      assert output =~ "worktree #{path} on branch card-#{ctx.card.id}"
      assert output =~ "wt=#{path}"
      assert output =~ "worktree #{path} removed"
      refute File.exists?(path)
      refute git(repo, ["branch", "--list", "card-#{ctx.card.id}"]) =~ "card-"
    end

    test "off: the job runs where the runner does, and no worktree is made", ctx do
      repo = repo(ctx)
      {:ok, queued} = queue(ctx.card, "pwd")
      {_, 0} = run_once(ctx, lanes(ctx, repo, "$Worktree = $false"))

      assert read(ctx, "out") == ctx.dir
      refute job(queued).output =~ "worktree"
      refute File.exists?("#{repo}-lanes")
    end

    test "a worktree with uncommitted changes is kept, and the next job reuses it", ctx do
      repo = repo(ctx)
      path = lane_path(repo, ctx.card)

      {:ok, first} = queue(ctx.card, "dirty")
      {_, 0} = run_once(ctx, lanes(ctx, repo))
      assert job(first).output =~ "worktree #{path} has uncommitted changes, so it is kept"
      assert File.exists?(Path.join(path, "scratch.txt"))

      {:ok, second} = queue(ctx.card, "pwd")
      {_, 0} = run_once(ctx, lanes(ctx, repo))
      assert %{status: "done", output: output} = job(second)
      assert output =~ "worktree #{path} (kept from before) on card-#{ctx.card.id}"
    end

    test "a directory that is not a git repository runs the job in place, saying so", ctx do
      plain = Path.join(ctx.dir, "plain")
      File.mkdir_p!(plain)
      {:ok, queued} = queue(ctx.card, "pwd")
      {_, 0} = run_once(ctx, lanes(ctx, plain))

      assert %{status: "done", output: output} = job(queued)
      assert output =~ "#{plain} is not a git repository, so no worktree"
      assert read(ctx, "out") == ctx.dir
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

      {out, 1} =
        System.cmd(@pwsh, ["-NoProfile", "-File", @script, "-Config", config(%{ctx | url: url})],
          cd: ctx.dir,
          stderr_to_stdout: true
        )

      {out, Stub.claims(stub)}
    end

    defp gaps(claims),
      do: claims |> Enum.chunk_every(2, 1, :discard) |> Enum.map(fn [a, b] -> b - a end)

    test "a claim the proxy lost is asked again a second later, without a word", ctx do
      {out, claims} = run_against(ctx, [{502, []}, {504, []}])

      assert length(claims) == 3
      refute out =~ "could not reach the queue"
      assert out =~ "refused this runner (HTTP 401)"
      assert Enum.all?(gaps(claims), &(&1 >= 900))
    end

    test "gateway errors that go on are logged after the first three", ctx do
      {out, claims} = run_against(ctx, List.duplicate({502, []}, 4))

      assert length(claims) == 5
      assert [_] = Regex.scan(~r/could not reach the queue \(HTTP 502\)/, out)
    end

    test "a draining server's Retry-After is waited out before asking again", ctx do
      {out, claims} = run_against(ctx, [{204, [{"retry-after", "2"}]}])

      assert [gap] = gaps(claims)
      assert gap >= 1_900
      refute out =~ "could not reach the queue"
    end

    test "under -Once a lost claim is still an error", ctx do
      {url, _stub, server} = Stub.start([{502, []}])
      on_exit(fn -> Process.exit(server, :normal) end)

      {out, 1} = run_once(ctx, config(%{ctx | url: url}))
      assert out =~ "could not reach the queue (HTTP 502)"
    end
  end

  describe "install.ps1" do
    # Task Scheduler is Windows-only, so this reads what the installer
    # registers (#1481): restart-on-failure doesn't cover a runner that
    # started and then exited, so a repeating trigger brings it back, and
    # IgnoreNew keeps that from starting a second one beside it.
    test "the task starts at logon and again every 5 minutes, never twice at once" do
      script = SlipdockWeb.RunnerInstallController.files()["install.ps1"]

      assert script =~ "New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME"

      assert script =~
               ~r/New-ScheduledTaskTrigger -Once -At \(Get-Date\) -RepetitionInterval \(New-TimeSpan -Minutes 5\)/

      assert script =~ "-MultipleInstances IgnoreNew"
      assert script =~ "within 5 minutes if it stops"
    end

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

    test "-Worktree (#1627): off by default; on, the job goes to the runner's worktree", ctx do
      work = Path.join(ctx.dir, "work")
      lane = Path.join(ctx.dir, "lane")
      File.mkdir_p!(work)
      File.mkdir_p!(lane)
      base = ["-Url", ctx.url, "-Token", "sdr_x", "-Cwd", work, "-Agent", "custom"]

      {_, 0} = install(ctx, base ++ ["-Command", "(Get-Location).Path"])
      assert installed(ctx, "Worktree") == ""

      {_, 0} = install(ctx, base ++ ["-Command", "(Get-Location).Path", "-Worktree"])
      assert installed(ctx, "Worktree") == "True"
      assert installed(ctx, "WorktreeRepo") == work

      cfg = Path.join([ctx.dir, "inst", "config.ps1"])

      run = fn env ->
        {out, 0} =
          System.cmd(@pwsh, ["-NoProfile", "-Command", ". '#{cfg}'; Job-Custom"], env: env)

        String.trim(out)
      end

      assert run.([{"SLIPDOCK_WORKTREE", nil}]) == work
      assert run.([{"SLIPDOCK_WORKTREE", lane}]) == lane
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

      # PowerShell matches without case unless told: a pool the server would
      # never send jobs for.
      {out, code} = install(ctx, ["-Url", ctx.url, "-Token", "t", "-Pool", "Dev"])
      assert code != 0
      assert out =~ "-Pool must be"

      {out, code} = install(ctx, ["-Url", ctx.url, "-Token", "t", "-Kind", "Big"])
      assert code != 0
      assert out =~ "-Kind must be"
    end

    test "claude may use the Slipdock tools, both names by default, or those named", ctx do
      {_, 0} = install(ctx, ["-Url", ctx.url, "-Token", "t"])
      assert installed(ctx, "AllowedTools") == "mcp__claude_ai_Slipdock,mcp__slipdock"

      assert File.read!(Path.join([ctx.dir, "inst", "config.ps1"])) =~
               "--permission-mode $PermissionMode --allowedTools $AllowedTools\n"

      {_, 0} = install(ctx, ["-Url", ctx.url, "-Token", "t", "-McpServers", "my-slipdock"])
      assert installed(ctx, "AllowedTools") == "mcp__my-slipdock"

      {_, 0} = install(ctx, ["-Url", ctx.url, "-Token", "t", "-Agent", "codex"])
      assert installed(ctx, "AllowedTools") == ""
      refute File.read!(Path.join([ctx.dir, "inst", "config.ps1"])) =~ "--allowedTools"

      {out, code} = install(ctx, ["-Url", ctx.url, "-Token", "t", "-McpServers", "a b;c"])
      assert code != 0
      assert out =~ "-McpServers must be names"
    end

    test "-Cwd under ~ is the runner's own home; another user's is refused", ctx do
      home =
        String.trim(
          elem(System.cmd(@pwsh, ["-NoProfile", "-Command", "[Console]::Out.Write($HOME)"]), 0)
        )

      {_, 0} = install(ctx, ["-Url", ctx.url, "-Token", "t", "-Cwd", "~/it's x"])
      assert installed(ctx, "WorkDir") == Path.join(home, "it's x")

      assert File.read!(Path.join([ctx.dir, "inst", "config.ps1"])) =~
               "$WorkDir = Join-Path $HOME 'it''s x'"

      {_, 0} = install(ctx, ["-Url", ctx.url, "-Token", "t", "-Cwd", "~"])
      assert installed(ctx, "WorkDir") == home

      {_, 0} = install(ctx, ["-Url", ctx.url, "-Token", "t", "-Cwd", "C:\\src\\~x"])
      assert installed(ctx, "WorkDir") == "C:\\src\\~x"

      {out, code} = install(ctx, ["-Url", ctx.url, "-Token", "t", "-Cwd", "~bob/x"])
      assert code != 0
      assert out =~ "-Cwd can't be another user's ~"
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

    defp installed_from(file, var) do
      {out, 0} =
        System.cmd(@pwsh, ["-NoProfile", "-Command", ". '#{file}'; [Console]::Out.Write($#{var})"])

      out
    end

    test "a named runner gets its own config and log beside the first, and runs", ctx do
      inst = Path.join(ctx.dir, "inst")
      {_, 0} = install(ctx, ["-Url", ctx.url, "-Token", "sdr_first", "-Pool", "loop"])
      first = File.read!(Path.join(inst, "config.ps1"))

      {out, 0} =
        install(ctx, [
          "-Url",
          ctx.url,
          "-Token",
          ctx.token,
          "-Pool",
          "dev",
          "-Name",
          "two",
          "-Agent",
          "custom",
          "-Command",
          "Write-Output \"ran: $env:SLIPDOCK_PROMPT\"",
          "-Cwd",
          ctx.dir
        ])

      named = Path.join(inst, "config-two.ps1")
      assert out =~ "name two"
      assert out =~ ~s(-Config "#{named}")
      assert File.read!(Path.join(inst, "config.ps1")) == first
      assert Path.wildcard(Path.join(inst, "*.bak.*")) == []
      assert installed_from(named, "RunnerToken") == ctx.token

      {:ok, queued} = queue(ctx.card, "custom", "the card")

      {_out, 0} =
        System.cmd(
          @pwsh,
          [
            "-NoProfile",
            "-File",
            Path.join(inst, "slipdock-runner.ps1"),
            "-Once",
            "-Config",
            named
          ],
          stderr_to_stdout: true
        )

      assert %{status: "done"} = job(queued)
      assert File.read!(Path.join(inst, "runner-two.log")) =~ "slipdock-runner:"
      refute File.exists?(Path.join(inst, "runner.log"))
    end

    test "unnamed over another pool's runner is refused, unless -Replace", ctx do
      inst = Path.join(ctx.dir, "inst")
      {_, 0} = install(ctx, ["-Url", ctx.url, "-Token", "sdr_first", "-Pool", "loop"])
      first = File.read!(Path.join(inst, "config.ps1"))

      {out, code} = install(ctx, ["-Url", ctx.url, "-Token", "sdr_new", "-Pool", "dev"])
      assert code != 0
      assert out =~ "is another runner's"
      assert out =~ "-Name NAME"
      assert File.read!(Path.join(inst, "config.ps1")) == first

      {_, 0} = install(ctx, ["-Url", ctx.url, "-Token", "sdr_new", "-Pool", "dev", "-Replace"])
      assert installed(ctx, "Pool") == "dev"
      assert [_] = Path.wildcard(Path.join(inst, "config.ps1.bak.*"))
    end

    test "a -Name that isn't one is refused", ctx do
      for name <- ["Two", "a/b", "-x"] do
        {out, code} = install(ctx, ["-Url", ctx.url, "-Token", "t", "-Name", name])
        assert code != 0, name
        assert out =~ "-Name must be", name
      end
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

    # What to do to the card and Nothing's paragraph come first, then the free text.
    assert token == "sdr_t'ok|" <> Slipdock.Runners.Setup.instructions(a) <> "|600"
    assert token =~ "What to do to the card: Don't move the card"
    assert token =~ "\n\nDon't push. '@ here|600"
  end

  test "the wizard's Windows claude one-liner carries the Slipdock tools, on or off", ctx do
    installer = Path.join(ctx.dir, "install.ps1")
    File.write!(installer, SlipdockWeb.RunnerInstallController.files()["install.ps1"])
    cfg = Path.join([ctx.dir, "inst", "config.ps1"])

    for {tools, expected} <- [{"true", "mcp__claude_ai_Slipdock,mcp__slipdock"}, {"false", ""}] do
      {:ok, a} =
        Slipdock.Runners.Setup.normalise(%{
          "scenario" => "windows",
          "cwd" => ctx.dir,
          "slipdock_tools" => tools
        })

      line = Slipdock.Runners.Setup.windows_one_liner(a, %{base_url: ctx.url, token: "sdr_t"})

      command =
        String.replace(line, ~r/\(irm '[^']+'\)/, "(Get-Content -Raw '#{installer}')") <>
          " `\n  -InstallDir '#{ctx.dir}/inst' -NoStart"

      {out, 0} = System.cmd(@pwsh, ["-NoProfile", "-Command", command], stderr_to_stdout: true)
      assert out =~ "installed"

      {allowed, 0} =
        System.cmd(@pwsh, [
          "-NoProfile",
          "-Command",
          ". '#{cfg}'; [Console]::Out.Write($AllowedTools)"
        ])

      assert allowed == expected
      assert File.read!(cfg) =~ "--allowedTools" == (expected != "")
    end
  end

  describe "the live log (#1870)" do
    # Writes a transcript where Claude Code would: one line naming the card,
    # then a line every half second, a too-long one and some tokens.
    defp transcript_config(ctx, extra \\ "") do
      tx = Path.join([ctx.dir, "projects", "-work-app", "session.jsonl"])
      saved = Path.join(ctx.dir, "cfg/slipdock/token")
      File.mkdir_p!(Path.dirname(saved))
      File.write!(saved, "abcdefghsaved0123456789\n")

      config(ctx, """
      $Transcripts = '#{ctx.dir}/projects'
      $TranscriptEvery = 1
      $TranscriptLine = 200
      $env:XDG_CONFIG_HOME = '#{ctx.dir}/cfg'
      $env:SLIPDOCK_TOKEN = 'abcdefghenv0123456789'
      function Job-Tx {
        $t = '#{tx}'
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $t) | Out-Null
        $u = New-Object System.Text.UTF8Encoding($false)
        [IO.File]::WriteAllText($t, ('{"n":0,"text":"' + $env:SLIPDOCK_CARD_URL + '"}' + "`n"), $u)
        foreach ($i in 1..6) { [IO.File]::AppendAllText($t, ('{"n":' + $i + '}' + "`n"), $u); Start-Sleep -Milliseconds 500 }
        [IO.File]::AppendAllText($t, ('{"n":7,"text":"' + ('x' * 300) + '"}' + "`n"), $u)
        $saved = ([IO.File]::ReadAllText('#{saved}')).Trim()
        [IO.File]::AppendAllText($t, ('{"n":8,"text":"runner ' + $RunnerToken + ' env ' + $env:SLIPDOCK_TOKEN + ' saved ' + $saved + '"}' + "`n"), $u)
        [IO.File]::AppendAllText($t, '{"n":9,"partial":', $u)
      }
      #{extra}
      """)
    end

    defp transcript(job), do: job |> job() |> Slipdock.Runners.Transcript.read()

    test "sends the transcript while the job runs, and the rest as it ends", ctx do
      {:ok, queued} = queue(ctx.card, "tx")
      running = Task.async(fn -> run_once(ctx, transcript_config(ctx)) end)

      wait_for(fn ->
        j = job(queued)
        j.status == "running" and j.transcript_lines >= 2
      end)

      {out, 0} = Task.await(running, 45_000)
      done = job(queued)
      assert done.status == "done", out
      assert done.transcript_lines == 9
      assert done.output =~ "sending the transcript"

      lines = queued |> transcript() |> String.split("\n", trim: true)
      assert length(lines) == 9
      assert Enum.map(Enum.take(lines, 7), &Jason.decode!(&1)["n"]) == Enum.to_list(0..6)
      assert hd(lines) =~ "/cards/#{ctx.card.id}"

      assert Jason.decode!(Enum.at(lines, 7)) ==
               %{
                 "type" => "slipdock_cut",
                 "bytes" => byte_size(~s({"n":7,"text":""})) + 300,
                 "limit" => 200
               }

      last = List.last(lines)
      refute last =~ ctx.token
      refute last =~ "abcdefghenv0123456789"
      refute last =~ "abcdefghsaved0123456789"
      assert last =~ "runner [redacted] env [redacted] saved [redacted]"
      refute transcript(queued) =~ "partial"
    end

    test "only a transcript written since the job started that names the card is sent", ctx do
      dir = Path.join([ctx.dir, "projects", "-elsewhere"])
      File.mkdir_p!(dir)
      old = Path.join(dir, "old.jsonl")
      File.write!(old, ~s({"old":"#{ctx.url}/boards/1/cards/#{ctx.card.id}"}\n))
      File.touch!(old, System.os_time(:second) - 600)

      extra = """
      function Job-Other {
        [IO.File]::WriteAllText('#{dir}/other.jsonl', ('{"other":"another session"}' + "`n"))
        Start-Sleep -Seconds 2
      }
      """

      {:ok, queued} = queue(ctx.card, "other")
      {_out, 0} = run_once(ctx, transcript_config(ctx, extra))
      assert job(queued).status == "done"
      assert job(queued).transcript_lines == 0
      refute (job(queued).output || "") =~ "sending the transcript"
    end

    test "sends that fail leave the job running, and the next one catches up", ctx do
      url = SlipdockWeb.FlakyTranscripts.start(fail: 4)
      {:ok, queued} = queue(ctx.card, "tx")
      {out, 0} = run_once(%{ctx | url: url}, transcript_config(%{ctx | url: url}))

      assert out =~ "could not send the transcript (HTTP 503); trying again later"
      assert SlipdockWeb.FlakyTranscripts.failed() == 4
      done = job(queued)
      assert {done.status, done.exit_code} == {"done", 0}
      assert done.transcript_lines == 9
    end
  end
end
