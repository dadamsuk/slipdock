defmodule SlipdockWeb.RunnerSkillsUpdateTest do
  @moduledoc """
  One source for each skill (#2048): before a job, a runner with
  `SKILLS_UPDATE` on (or unset, with `SELF_UPDATE` on) puts the server's
  skills from `/api/skills.tar.gz` in place of the copies in its skills
  directory, so no machine keeps a hand-edited second copy. Run for real (sh,
  and pwsh where installed) against this app on a loopback port, with the
  skills directory and `curl` in a temporary directory.
  """
  use Slipdock.DataCase, async: false

  import Slipdock.Fixtures

  alias Slipdock.{Repo, Runners}
  alias Slipdock.Runners.Job

  @pwsh System.get_env("SLIPDOCK_PWSH") || System.find_executable("pwsh")
  @root Path.expand("../..", __DIR__)

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

    dir = Path.join(System.tmp_dir!(), "slipdock-skillsup-#{System.unique_integer([:positive])}")
    skills = Path.join(dir, "skills")
    # A stale copy, with a file the server's no longer has, and a skill that
    # isn't Slipdock's.
    File.mkdir_p!(Path.join(skills, "slipdock-loop"))
    File.write!(Path.join([skills, "slipdock-loop", "SKILL.md"]), "# An old loop\n")
    File.write!(Path.join([skills, "slipdock-loop", "gone.md"]), "stale\n")
    File.mkdir_p!(Path.join(skills, "other-skill"))
    File.write!(Path.join([skills, "other-skill", "SKILL.md"]), "# Not ours\n")
    on_exit(fn -> File.rm_rf!(dir) end)

    board = board_fixture()
    card = card_fixture(hd(board.columns), %{"title" => "Run me"})
    {:ok, runner, token} = Runners.create_runner(board, %{"name" => "sk", "pool" => "dev"})
    {:ok, job} = Runners.queue(card, %{pool: "dev", kind: "echo", prompt: "go"})

    %{
      url: "http://127.0.0.1:#{port}",
      dir: dir,
      skills: skills,
      column: hd(board.columns),
      runner: runner,
      token: token,
      job: job
    }
  end

  defp packaged(name), do: File.read!(Path.join([@root, "priv/skills", name, "SKILL.md"]))
  defp installed(ctx, name), do: File.read(Path.join([ctx.skills, name, "SKILL.md"]))

  defp assert_untouched(ctx) do
    assert installed(ctx, "slipdock-loop") == {:ok, "# An old loop\n"}
    assert File.exists?(Path.join([ctx.skills, "slipdock-loop", "gone.md"]))
    refute File.exists?(Path.join(ctx.skills, "slipdock"))
  end

  # A curl that answers the skills archive with `answer` (a shell snippet
  # writing to "$out", or failing) and passes everything else to the real one.
  defp curl_stub(ctx, answer) do
    bin = Path.join(ctx.dir, "bin")
    File.mkdir_p!(bin)
    real = System.find_executable("curl")

    File.write!(Path.join(bin, "curl"), """
    #!/bin/sh
    out=
    prev=
    for a in "$@"; do [ "$prev" = -o ] && out=$a; prev=$a; done
    case "$*" in
      *skills.tar.gz*) #{answer} ;;
      *) exec '#{real}' "$@" ;;
    esac
    """)

    File.chmod!(Path.join(bin, "curl"), 0o755)
    [{"PATH", bin <> ":" <> System.get_env("PATH")}]
  end

  describe "the shell runner" do
    defp run(ctx, extra, env \\ []) do
      config = Path.join(ctx.dir, "config")

      File.write!(config, """
      SLIPDOCK_URL='#{ctx.url}'
      SLIPDOCK_RUNNER_TOKEN='#{ctx.token}'
      WAIT=0
      SKILLS_DIR='#{ctx.skills}'
      job_echo() { cat '#{ctx.skills}/slipdock-loop/SKILL.md' >'#{ctx.dir}/seen'; }
      #{extra}
      """)

      {out, code} =
        System.cmd(
          "sh",
          [Path.join([@root, "priv/runner/slipdock-runner"]), "--once", "--config=#{config}"],
          cd: ctx.dir,
          env: [{"TMPDIR", ctx.dir} | env],
          stderr_to_stdout: true
        )

      assert code == 0, out
      assert Repo.get!(Job, ctx.job.id).status == "done", out
      out
    end

    test "with SKILLS_UPDATE=1, the job's agent reads the server's skills", ctx do
      out = run(ctx, "SKILLS_UPDATE=1")

      assert out =~ "skills: installed the server's slipdock "
      assert installed(ctx, "slipdock-loop") == {:ok, packaged("slipdock-loop")}
      assert installed(ctx, "slipdock") == {:ok, packaged("slipdock")}
      # Put in place before the job ran, not after.
      assert File.read!(Path.join(ctx.dir, "seen")) == packaged("slipdock-loop")
      # The copy is replaced whole, and a skill that isn't Slipdock's is left.
      refute File.exists?(Path.join([ctx.skills, "slipdock-loop", "gone.md"]))
      assert installed(ctx, "other-skill") == {:ok, "# Not ours\n"}
    end

    test "SELF_UPDATE=1 turns it on, and SKILLS_UPDATE=0 keeps it off", ctx do
      run(ctx, "SELF_UPDATE=1\nSKILLS_UPDATE=0")
      assert_untouched(ctx)

      card = card_fixture(ctx.column, %{"title" => "Run me again"})
      {:ok, again} = Runners.queue(card, %{pool: "dev", kind: "echo", prompt: "again"})
      run(%{ctx | job: again}, "SELF_UPDATE=1")
      assert installed(ctx, "slipdock-loop") == {:ok, packaged("slipdock-loop")}
    end

    test "off when the config sets neither, so nothing is changed", ctx do
      out = run(ctx, "")
      refute out =~ "skills:"
      assert_untouched(ctx)
    end

    test "a skill folder that is a symlink is left alone", ctx do
      checkout = Path.join(ctx.dir, "checkout-loop")
      File.mkdir_p!(checkout)
      File.write!(Path.join(checkout, "SKILL.md"), "# A checkout's loop\n")
      File.rm_rf!(Path.join(ctx.skills, "slipdock-loop"))
      File.ln_s!(checkout, Path.join(ctx.skills, "slipdock-loop"))

      out = run(ctx, "SKILLS_UPDATE=1")

      assert out =~ "slipdock-loop is a symlink; left alone"
      assert File.read!(Path.join(checkout, "SKILL.md")) == "# A checkout's loop\n"
      assert installed(ctx, "slipdock") == {:ok, packaged("slipdock")}
    end

    test "a failed fetch keeps the copies there, and the job still runs", ctx do
      out = run(ctx, "SKILLS_UPDATE=1", curl_stub(ctx, "exit 22"))

      assert out =~ "skills: could not fetch the server's skills"
      assert_untouched(ctx)
    end

    test "an archive with an entry outside a slipdock skill is refused", ctx do
      evil = Path.join(ctx.dir, "evil")
      File.mkdir_p!(Path.join(evil, "slipdock"))
      File.write!(Path.join([evil, "slipdock", "SKILL.md"]), "# evil\n")
      File.write!(Path.join(evil, "elsewhere"), "x\n")

      {_, 0} =
        System.cmd("tar", [
          "-czf",
          Path.join(ctx.dir, "evil.tgz"),
          "-C",
          evil,
          "slipdock",
          "elsewhere"
        ])

      out = run(ctx, "SKILLS_UPDATE=1", curl_stub(ctx, ~s|cp '#{ctx.dir}/evil.tgz' "$out"|))

      assert out =~
               "skills: the server's archive has an entry outside a slipdock skill (elsewhere)"

      assert_untouched(ctx)
      refute File.exists?(Path.join(ctx.skills, "elsewhere"))
    end
  end

  describe "the PowerShell runner" do
    if is_nil(@pwsh),
      do: @describetag(skip: "pwsh (PowerShell) is not installed here; CI runs these")

    defp ps_run(ctx, extra) do
      config = Path.join(ctx.dir, "config.ps1")

      File.write!(config, """
      $SlipdockUrl = '#{ctx.url}'
      $RunnerToken = '#{ctx.token}'
      $Pool = 'dev'
      $Wait = 0
      $SkillsDir = '#{ctx.skills}'
      function Job-Echo { Get-Content -Raw '#{ctx.skills}/slipdock-loop/SKILL.md' | Set-Content -NoNewline '#{ctx.dir}/seen' }
      #{extra}
      """)

      {out, code} =
        System.cmd(
          "timeout",
          [
            "-k",
            "5",
            "40",
            @pwsh,
            "-NoProfile",
            "-File",
            Path.join([@root, "priv/runner/slipdock-runner.ps1"]),
            "-Once",
            "-Config",
            config
          ],
          cd: ctx.dir,
          stderr_to_stdout: true
        )

      assert code == 0, out
      assert Repo.get!(Job, ctx.job.id).status == "done", out
      out
    end

    test "with $SkillsUpdate on, the job's agent reads the server's skills", ctx do
      out = ps_run(ctx, "$SkillsUpdate = $true")

      assert out =~ "skills: installed the server's slipdock "
      assert installed(ctx, "slipdock-loop") == {:ok, packaged("slipdock-loop")}
      assert File.read!(Path.join(ctx.dir, "seen")) == packaged("slipdock-loop")
      refute File.exists?(Path.join([ctx.skills, "slipdock-loop", "gone.md"]))
      assert installed(ctx, "other-skill") == {:ok, "# Not ours\n"}
    end

    test "$SelfUpdate on with $SkillsUpdate off changes nothing", ctx do
      out = ps_run(ctx, "$SelfUpdate = $true\n$SkillsUpdate = $false")
      refute out =~ "skills:"
      assert_untouched(ctx)
    end
  end
end
