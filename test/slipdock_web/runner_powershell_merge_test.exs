defmodule SlipdockWeb.RunnerPowerShellMergeTest do
  # Ship by PR 3 (#1656): the PowerShell runner's built-in merge kind, run
  # for real under `pwsh` (when installed; CI has it) against this app, with
  # a stand-in `gh` on the PATH and a repository whose origin is on GitHub.
  use Slipdock.DataCase, async: false

  import Slipdock.Fixtures

  alias Slipdock.{Repo, Runners}
  alias Slipdock.Runners.{Job, Runner}

  @script Path.expand("../../priv/runner/slipdock-runner.ps1", __DIR__)
  @pwsh System.get_env("SLIPDOCK_PWSH") || System.find_executable("pwsh")
  @head "0123456789abcdef0123456789abcdef01234567"
  @merged "fedcba9876543210fedcba9876543210fedcba98"

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

    dir = Path.join(System.tmp_dir!(), "slipdock-psmerge-#{System.unique_integer([:positive])}")
    repo = Path.join(dir, "repo")
    File.mkdir_p!(repo)
    on_exit(fn -> File.rm_rf!(dir) end)

    {_, 0} = System.cmd("git", ["init", "-q"], cd: repo)

    {_, 0} =
      System.cmd("git", ["remote", "add", "origin", "git@github.com:acme/widgets.git"], cd: repo)

    bin = Path.join(dir, "bin")
    File.mkdir_p!(bin)

    File.write!(Path.join(bin, "gh"), ~S"""
    #!/bin/sh
    echo "gh $*" >>"$FAKE_GH_LOG"
    case "$1 $2" in
      "auth status") exit "${FAKE_GH_AUTH:-0}" ;;
      "pr view")
        case "$*" in
          *mergeCommit*) echo "$FAKE_GH_MERGED" ;;
          *) echo "${FAKE_GH_STATE:-OPEN} $FAKE_GH_HEAD" ;;
        esac
        exit 0
        ;;
      "pr merge") exit "${FAKE_GH_MERGE:-0}" ;;
    esac
    exit 1
    """)

    File.chmod!(Path.join(bin, "gh"), 0o755)

    board = board_fixture()

    card =
      hd(board.columns)
      |> card_fixture(%{"title" => "Ship it"})
      |> Ecto.Changeset.change(
        evidence_pr: "https://github.com/acme/widgets/pull/12",
        evidence_commit: String.slice(@head, 0, 10)
      )
      |> Repo.update!()

    {:ok, runner, token} = Runners.create_runner(board, %{"name" => "ps", "pool" => "dev"})

    %{
      url: "http://127.0.0.1:#{port}",
      dir: dir,
      repo: repo,
      bin: bin,
      card: card,
      runner: runner,
      token: token
    }
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
    function Job-Claude { Write-Output 'claude' }
    function Job-TwoWords { Write-Output 'dashed' }
    #{extra}
    """)

    path
  end

  defp run_once(ctx, config, env \\ []) do
    System.cmd(@pwsh, ["-NoProfile", "-File", @script, "-Once", "-Config", config],
      cd: ctx.repo,
      env:
        [
          {"PATH", "#{ctx.bin}:#{System.get_env("PATH")}"},
          {"FAKE_GH_LOG", gh_log(ctx)},
          {"FAKE_GH_HEAD", @head},
          {"FAKE_GH_MERGED", @merged}
        ] ++ env,
      stderr_to_stdout: true
    )
  end

  defp gh_log(ctx), do: Path.join(ctx.dir, "gh.log")
  defp gh_calls(ctx), do: if(File.exists?(gh_log(ctx)), do: File.read!(gh_log(ctx)), else: "")
  defp queue_merge(card), do: Runners.queue(card, %{pool: "dev", kind: "merge", prompt: "merge"})
  defp job(job), do: Repo.get!(Job, job.id)

  test "merges the accepted commit's pull request and reports the merge commit", ctx do
    {:ok, queued} = queue_merge(ctx.card)
    {out, 0} = run_once(ctx, config(ctx))

    done = job(queued)
    assert done.status == "done", out <> (done.output || "")
    assert done.merged_sha == @merged

    assert gh_calls(ctx) =~
             "gh pr merge 12 --repo acme/widgets --merge --match-head-commit #{@head} " <>
               "--subject Merge pull request #12: card ##{ctx.card.id}"

    assert Repo.get!(Runner, ctx.runner.id).kinds == ["claude", "merge", "two-words"]
  end

  test "a head that moved is not merged", ctx do
    {:ok, queued} = queue_merge(ctx.card)
    {_out, 0} = run_once(ctx, config(ctx), [{"FAKE_GH_HEAD", String.duplicate("9", 40)}])

    failed = job(queued)
    assert failed.status == "failed"
    assert failed.output =~ "not the accepted commit"
    assert failed.merged_sha == nil
    refute gh_calls(ctx) =~ "pr merge"
  end

  test "a pull request in another repository is refused before gh is asked", ctx do
    ctx.card
    |> Ecto.Changeset.change(evidence_pr: "https://github.com/evil/other/pull/12")
    |> Repo.update!()

    {:ok, queued} = queue_merge(ctx.card)
    {_out, 0} = run_once(ctx, config(ctx))

    assert job(queued).status == "failed"
    assert job(queued).output =~ "the pull request is in evil/other"
    assert gh_calls(ctx) == ""
  end

  test "a closed pull request, or a refused merge, fails with the reason", ctx do
    {:ok, queued} = queue_merge(ctx.card)
    {_out, 0} = run_once(ctx, config(ctx), [{"FAKE_GH_STATE", "MERGED"}])
    assert job(queued).output =~ "is MERGED, not open"

    {:ok, queued} = queue_merge(ctx.card)
    {_out, 0} = run_once(ctx, config(ctx), [{"FAKE_GH_MERGE", "1"}])
    assert job(queued).exit_code == 3
    assert job(queued).output =~ "gh pr merge refused"
  end

  test "$Merge = $false turns it off; a config's own Job-Merge replaces it", ctx do
    {:ok, queued} = queue_merge(ctx.card)
    {_out, 0} = run_once(ctx, config(ctx, "$Merge = $false"))
    assert Repo.get!(Runner, ctx.runner.id).kinds == ["claude", "two-words"]
    assert job(queued).status == "queued"

    {_out, 0} =
      run_once(
        ctx,
        config(ctx, ~S|function Job-Merge { Write-Output "mine: $env:SLIPDOCK_MERGE_PR" }|)
      )

    assert job(queued).status == "done"
    assert job(queued).output =~ "mine: https://github.com/acme/widgets/pull/12"
    assert gh_calls(ctx) == ""
  end
end
