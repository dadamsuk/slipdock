defmodule Slipdock.RunnersDriftScriptTest do
  @moduledoc """
  Skill and CLI drift (#1795), the runner's side: the shell runner (and the
  PowerShell one, where pwsh is installed) says on each claim the SHA-256 of
  each slipdock skill installed under its skills directory and of its CLI,
  run for real against this app on a loopback port.
  """
  use Slipdock.DataCase, async: false

  import Slipdock.Fixtures

  alias Slipdock.{Repo, Runners}
  alias Slipdock.Runners.Runner

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

    dir = Path.join(System.tmp_dir!(), "slipdock-driftsh-#{System.unique_integer([:positive])}")
    skills = Path.join(dir, "skills")
    File.mkdir_p!(Path.join(skills, "slipdock-loop"))
    File.mkdir_p!(Path.join(skills, "slipdock"))
    File.mkdir_p!(Path.join(skills, "other-skill"))
    # CRLF endings hash as the LF text does: an editor on Windows is no drift.
    File.write!(Path.join([skills, "slipdock-loop", "SKILL.md"]), "# Loop\r\nsteps\r\n")
    File.write!(Path.join([skills, "slipdock", "SKILL.md"]), "# Slipdock\n")
    File.write!(Path.join([skills, "other-skill", "SKILL.md"]), "# Not ours\n")
    cli = Path.join(dir, "slipdock")
    File.write!(cli, "#!/bin/sh\necho cli\n")
    on_exit(fn -> File.rm_rf!(dir) end)

    board = board_fixture()
    {:ok, runner, token} = Runners.create_runner(board, %{"name" => "sh", "pool" => "dev"})

    %{
      url: "http://127.0.0.1:#{port}",
      dir: dir,
      skills: skills,
      cli: cli,
      runner: runner,
      token: token
    }
  end

  defp sha(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  defp expected(cli) do
    %{
      skills: %{"slipdock-loop" => sha("# Loop\nsteps\n"), "slipdock" => sha("# Slipdock\n")},
      cli: sha(File.read!(cli))
    }
  end

  defp script(name), do: Path.join([File.cwd!(), "priv", "runner", name])

  describe "the shell runner" do
    defp config(ctx, extra) do
      path = Path.join(ctx.dir, "config")

      File.write!(path, """
      SLIPDOCK_URL='#{ctx.url}'
      SLIPDOCK_RUNNER_TOKEN='#{ctx.token}'
      WAIT=0
      job_echo() { echo hi; }
      #{extra}
      """)

      path
    end

    defp run(ctx, config, env \\ []) do
      System.cmd("sh", [script("slipdock-runner"), "--once", "--config=#{config}"],
        cd: ctx.dir,
        env: [{"TMPDIR", ctx.dir} | env],
        stderr_to_stdout: true
      )
    end

    test "says each installed slipdock skill and the CLI it is told of", ctx do
      {_out, 0} =
        run(ctx, config(ctx, "SKILLS_DIR='#{ctx.skills}'\nSLIPDOCK_CLI='#{ctx.cli}'"))

      runner = Repo.get!(Runner, ctx.runner.id)
      want = expected(ctx.cli)
      assert runner.skills == want.skills
      assert runner.cli_sha == want.cli
    end

    test "with no skills and no CLI it says none, which reads as no drift", ctx do
      empty = Path.join(ctx.dir, "empty")
      File.mkdir_p!(empty)

      {_out, 0} =
        run(ctx, config(ctx, "SKILLS_DIR='#{empty}'\nSLIPDOCK_CLI='#{ctx.dir}/missing'"))

      runner = Repo.get!(Runner, ctx.runner.id)
      assert runner.skills == %{}
      assert runner.cli_sha == "none"
      refute Slipdock.Runners.Drift.drifted?(Slipdock.Runners.Drift.states(runner))
    end

    test "finds the CLI on the PATH and the skills under HOME by default", ctx do
      bin = Path.join(ctx.dir, "bin")
      File.mkdir_p!(bin)
      File.cp!(ctx.cli, Path.join(bin, "slipdock"))
      File.chmod!(Path.join(bin, "slipdock"), 0o755)
      home = Path.join(ctx.dir, "home")
      File.mkdir_p!(Path.join(home, ".claude"))
      File.cp_r!(ctx.skills, Path.join([home, ".claude", "skills"]))

      {_out, 0} =
        run(ctx, config(ctx, ""), [{"HOME", home}, {"PATH", bin <> ":" <> System.get_env("PATH")}])

      runner = Repo.get!(Runner, ctx.runner.id)
      assert runner.skills == expected(ctx.cli).skills
      assert runner.cli_sha == expected(ctx.cli).cli
    end
  end

  describe "the PowerShell runner" do
    if is_nil(@pwsh),
      do: @describetag(skip: "pwsh (PowerShell) is not installed here; CI runs these")

    test "says each installed slipdock skill and the CLI it is told of", ctx do
      config = Path.join(ctx.dir, "config.ps1")

      File.write!(config, """
      $SlipdockUrl = '#{ctx.url}'
      $RunnerToken = '#{ctx.token}'
      $Wait = 0
      $SkillsDir = '#{ctx.skills}'
      $SlipdockCli = '#{ctx.cli}'
      function Job-Echo { Write-Output 'hi' }
      """)

      {out, code} =
        System.cmd(
          @pwsh,
          ["-NoProfile", "-File", script("slipdock-runner.ps1"), "-Once", "-Config", config],
          cd: ctx.dir,
          stderr_to_stdout: true
        )

      assert code == 0, out
      runner = Repo.get!(Runner, ctx.runner.id)
      want = expected(ctx.cli)
      assert runner.skills == want.skills
      assert runner.cli_sha == want.cli
    end
  end
end
