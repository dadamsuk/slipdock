defmodule SlipdockWeb.RunnerMergeTest do
  # Ship by PR 3 (#1656): the shell runner's built-in merge kind, run for
  # real under `sh` against this app on a loopback port, with a stand-in
  # `gh` on the PATH and a repository whose origin is on GitHub. It merges
  # only an open pull request in its own repository whose head is the
  # accepted commit, reports the merge commit, and fails with the reason
  # otherwise; runners say which kinds they take, and only those that take
  # merge are handed merge jobs.
  use Slipdock.DataCase, async: false

  import Slipdock.Fixtures

  alias Slipdock.{Repo, Runners}
  alias Slipdock.Boards.Card
  alias Slipdock.Runners.{Job, Runner}

  @script Path.expand("../../priv/runner/slipdock-runner", __DIR__)
  @head "0123456789abcdef0123456789abcdef01234567"
  @merged "fedcba9876543210fedcba9876543210fedcba98"

  # The commands the runner and its merge need, for a PATH with no gh on it.
  @tools ~w(sh curl git sed awk grep sort paste tr cat mktemp chmod rm date ps sleep head
            tail mv kill env dirname basename cut wc mkdir ls uname id)

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

    dir = Path.join(System.tmp_dir!(), "slipdock-merge-#{System.unique_integer([:positive])}")
    repo = Path.join(dir, "repo")
    File.mkdir_p!(repo)
    on_exit(fn -> File.rm_rf!(dir) end)

    {_, 0} = System.cmd("git", ["init", "-q"], cd: repo)

    {_, 0} =
      System.cmd("git", ["remote", "add", "origin", "https://github.com/Acme/widgets.git"],
        cd: repo
      )

    # A stand-in gh: answers from FAKE_* variables and logs what it was asked.
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
    card = card_fixture(hd(board.columns), %{"title" => "Ship it"})

    card =
      card
      |> Ecto.Changeset.change(
        evidence_pr: "https://github.com/acme/widgets/pull/12",
        evidence_commit: String.slice(@head, 0, 12)
      )
      |> Repo.update!()

    {:ok, runner, token} = Runners.create_runner(board, %{"name" => "sh", "pool" => "dev"})

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
    path = Path.join(ctx.dir, "config")

    File.write!(path, """
    SLIPDOCK_URL='#{ctx.url}'
    SLIPDOCK_RUNNER_TOKEN='#{ctx.token}'
    WAIT=0
    HEARTBEAT=1
    JOB_TIMEOUT=30
    job_claude() { echo claude; }
    #{extra}
    """)

    path
  end

  defp run_once(ctx, config, env \\ [], path \\ nil) do
    path = path || "#{ctx.bin}:#{System.get_env("PATH")}"

    System.cmd("sh", [@script, "--once", "--config=#{config}"],
      cd: ctx.repo,
      env:
        [
          {"TMPDIR", ctx.dir},
          {"PATH", path},
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

    assert out =~ "job ##{queued.id}: merge for card ##{ctx.card.id}"
    done = job(queued)
    assert done.status == "done", done.output
    assert done.merged_sha == @merged
    assert done.output =~ "merged https://github.com/acme/widgets/pull/12"

    calls = gh_calls(ctx)

    assert calls =~
             "gh pr merge 12 --repo acme/widgets --merge --match-head-commit #{@head} " <>
               "--subject Merge pull request #12: card ##{ctx.card.id}"

    # It said what it takes: the config's kinds and the built-in merge.
    assert Repo.get!(Runner, ctx.runner.id).kinds == ["claude", "merge"]
  end

  test "a head that moved after the acceptance is not merged", ctx do
    {:ok, queued} = queue_merge(ctx.card)
    other = String.duplicate("9", 40)
    {_out, 0} = run_once(ctx, config(ctx), [{"FAKE_GH_HEAD", other}])

    failed = job(queued)
    assert failed.status == "failed"
    assert failed.output =~ "head is #{other}, not the accepted commit"
    assert failed.merged_sha == nil
    refute gh_calls(ctx) =~ "pr merge"
  end

  test "a pull request that is no longer open is not merged", ctx do
    {:ok, queued} = queue_merge(ctx.card)
    {_out, 0} = run_once(ctx, config(ctx), [{"FAKE_GH_STATE", "CLOSED"}])

    assert job(queued).status == "failed"
    assert job(queued).output =~ "is CLOSED, not open"
    refute gh_calls(ctx) =~ "pr merge"
  end

  test "a refused merge (a conflict) fails with the reason", ctx do
    {:ok, queued} = queue_merge(ctx.card)
    {_out, 0} = run_once(ctx, config(ctx), [{"FAKE_GH_MERGE", "1"}])

    failed = job(queued)
    assert failed.status == "failed"
    assert failed.exit_code == 3
    assert failed.output =~ "gh pr merge refused"
    assert failed.merged_sha == nil
  end

  test "a pull request in another repository than origin is refused before gh is asked", ctx do
    ctx.card
    |> Ecto.Changeset.change(evidence_pr: "https://github.com/evil/other/pull/12")
    |> Repo.update!()

    {:ok, queued} = queue_merge(ctx.card)
    {_out, 0} = run_once(ctx, config(ctx))

    failed = job(queued)
    assert failed.status == "failed"
    assert failed.output =~ "the pull request is in evil/other"
    assert gh_calls(ctx) == ""
  end

  test "a card with no pull request, or not a GitHub one, fails saying so", ctx do
    ctx.card |> Ecto.Changeset.change(evidence_pr: "https://example.com/x") |> Repo.update!()
    {:ok, queued} = queue_merge(ctx.card)
    {_out, 0} = run_once(ctx, config(ctx))
    assert job(queued).output =~ "is not a GitHub pull request URL"

    ctx.card |> Ecto.Changeset.change(evidence_pr: nil) |> Repo.update!()
    {:ok, queued} = queue_merge(ctx.card)
    {_out, 0} = run_once(ctx, config(ctx))
    assert job(queued).output =~ "names no pull request"
  end

  test "gh not signed in fails saying so", ctx do
    {:ok, queued} = queue_merge(ctx.card)
    {_out, 0} = run_once(ctx, config(ctx), [{"FAKE_GH_AUTH", "1"}])
    assert job(queued).status == "failed"
    assert job(queued).output =~ "gh is not signed in"
  end

  test "with no gh installed it fails saying so", ctx do
    tools = Path.join(ctx.dir, "tools")
    File.mkdir_p!(tools)

    for tool <- @tools,
        path = System.find_executable(tool),
        do: File.ln_s!(path, Path.join(tools, tool))

    {:ok, queued} = queue_merge(ctx.card)
    {_out, 0} = run_once(ctx, config(ctx), [], tools)

    assert job(queued).status == "failed"
    assert job(queued).output =~ "gh (GitHub CLI) is not installed"
  end

  test "MERGE=0 turns it off: the runner doesn't say merge and isn't handed the job", ctx do
    {:ok, queued} = queue_merge(ctx.card)
    {_out, 0} = run_once(ctx, config(ctx, "MERGE=0"))

    assert Repo.get!(Runner, ctx.runner.id).kinds == ["claude"]
    assert job(queued).status == "queued"
    assert gh_calls(ctx) == ""
  end

  test "a config's own job_merge replaces the built-in one", ctx do
    {:ok, queued} = queue_merge(ctx.card)

    {_out, 0} =
      run_once(ctx, config(ctx, ~S|job_merge() { echo "my merge of $SLIPDOCK_MERGE_PR"; }|))

    done = job(queued)
    assert done.status == "done"
    assert done.output =~ "my merge of https://github.com/acme/widgets/pull/12"
    assert gh_calls(ctx) == ""
  end

  test "a merge job doesn't make a worktree, even with WORKTREE on", ctx do
    {:ok, queued} = queue_merge(ctx.card)
    {_out, 0} = run_once(ctx, config(ctx, "WORKTREE=1"))

    assert job(queued).status == "done"
    refute File.exists?(Path.join(ctx.dir, "repo-lanes"))
    assert Repo.get!(Card, ctx.card.id)
  end
end
