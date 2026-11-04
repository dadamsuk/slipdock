defmodule SlipdockWeb.VerifyProgressTest do
  @moduledoc """
  Verify jobs report progress while they run (#1668): the verify prompt asks
  for a step at each stage and no note; the agent a runner started for a job
  may report a step on it (`x-slipdock-job`), which renews the lease, shows
  in the job's JSON and on the Runners panel, and adds nothing to the card.
  """
  use SlipdockWeb.ConnCase, async: true

  import Ecto.Query
  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Boards, Repo, Runners, Verified}
  alias Slipdock.Runners.Job

  setup %{user: user} do
    board = board_fixture(%{"name" => "Checks", "code" => unique_code()}, owner: user)
    doing = Enum.find(board.columns, &(&1.category == "doing"))
    card = card_fixture(doing, %{"title" => "Export header"})

    {:ok, runner, _token} =
      Runners.create_runner(board, %{"name" => "checker", "pool" => "checkers"})

    {:ok, job} =
      Runners.queue(card, %{
        pool: "checkers",
        kind: "verify",
        prompt: Verified.verify_prompt(card, board)
      })

    %Job{id: id} = Runners.claim(runner)
    assert id == job.id
    # The runner's own heartbeat: its log tail, which a step leaves alone.
    {:ok, :ok} = Runners.heartbeat(runner, job.id, "runner log line")

    %{board: board, card: card, runner: runner, job: Repo.get!(Job, job.id)}
  end

  # The CLI as the runner's agent runs it: an agent, inside job `job_id`.
  defp agent_conn(user, job_id) do
    conn_as(user)
    |> put_req_header("accept", "application/json")
    |> put_req_header("x-slipdock-client", "cli")
    |> put_req_header("x-slipdock-agent", "1")
    |> then(&if(job_id, do: put_req_header(&1, "x-slipdock-job", to_string(job_id)), else: &1))
  end

  defp comments(card),
    do: Boards.get_card!(card.id) |> Repo.preload(:comments) |> Map.get(:comments)

  describe "the verify prompt" do
    test "asks for a step at each stage, and no note", %{board: board, card: card} do
      {:ok, card} = Boards.update_card(card, %{"evidence_commit" => "abc1234"})
      prompt = Verified.verify_prompt(card, board)

      assert prompt =~ ~s(`slipdock job-progress --step "…"`)
      assert prompt =~ "$SLIPDOCK_JOB_ID"
      assert prompt =~ "MCP `job_progress` with `step`"
      assert prompt =~ "never a note or `--message`"
      assert prompt =~ "the card stays quiet until you decide"
      assert prompt =~ "`checked out abc1234`"
      assert prompt =~ "`tests running: <which>`"
      assert prompt =~ "`tests passed: <n>, failed: <n>`"
      assert prompt =~ "`judging against the bar`"
      assert prompt =~ "`deciding: accept`"
      refute prompt =~ "job-progress --message"
    end

    test "without a commit, the first step names none", %{board: board, card: card} do
      assert Verified.verify_prompt(card, board) =~ "`checked out <commit>`"
    end
  end

  describe "the verify prompt on a board that ships by pull request (#1808)" do
    @pr "https://github.com/acme/app/pull/9"

    setup %{board: board, card: card} do
      {:ok, board} =
        Boards.update_board(board, %{"verify_work" => true, "ship_via" => "pull_request"})

      {:ok, card} =
        Boards.update_card(card, %{"evidence_commit" => "abc1234", "evidence_pr" => @pr})

      %{board: board, card: card}
    end

    test "reads the change and checks the PR's CI, without running the suite", ctx do
      prompt = Verified.verify_prompt(ctx.card, ctx.board)

      assert prompt =~ "Check out abc1234 in a clean tree"
      assert prompt =~ "Don't run the suite: the pull request's CI runs it at this commit."

      assert prompt =~
               "`gh pr view #{@pr} --json headRefOid,statusCheckRollup`: the head must be abc1234"

      assert prompt =~ "reject it to be submitted again at its head"
      assert prompt =~ "While any is still running, wait (`gh pr checks #{@pr} --watch`)"
      assert prompt =~ "A failed check is a rejection: name it."

      assert prompt =~
               "If the pull request has no checks at all, run the suite in the clean tree instead."

      assert prompt =~ "`CI: <n> checks passed at abc1234`"
      assert prompt =~ "`judging against the bar`"
      refute prompt =~ "run the suite there"
      refute prompt =~ "`tests running: <which>`"

      # Still three steps, in order, the decision last.
      assert prompt =~ ~r/^1\. Read the card.*\n2\. Check out abc1234/m
      assert prompt =~ ~r/`judging against the bar`\n3\. Decide once/
    end

    test "with no pull request on the card, the suite is run as before", ctx do
      {:ok, card} = Boards.update_card(ctx.card, %{"evidence_pr" => nil})
      prompt = Verified.verify_prompt(card, ctx.board)

      assert prompt =~ "run the suite there"
      assert prompt =~ "`tests running: <which>`"
      refute prompt =~ "statusCheckRollup"
    end

    test "a board that ships by push runs the suite, pull request or not", ctx do
      {:ok, board} = Boards.update_board(ctx.board, %{"ship_via" => "push"})
      prompt = Verified.verify_prompt(ctx.card, board)

      assert prompt =~ "run the suite there"
      assert prompt =~ "`tests passed: <n>, failed: <n>`"
      refute prompt =~ "Don't run the suite"
    end
  end

  describe "a step from the job's own agent" do
    test "is kept on the job, renews the lease and adds no comment", ctx do
      before = comments(ctx.card)
      soon = DateTime.utc_now() |> DateTime.add(5) |> DateTime.truncate(:second)
      Repo.update_all(from(j in Job, where: j.id == ^ctx.job.id), set: [lease_expires_at: soon])

      assert %{"status" => "ok"} =
               agent_conn(ctx.user, ctx.job.id)
               |> post(~p"/api/jobs/#{ctx.job.id}/progress", %{
                 "step" => "tests running: mix test"
               })
               |> json_response(200)

      job = Repo.get!(Job, ctx.job.id)
      assert job.step == "tests running: mix test"
      assert job.step_at
      assert DateTime.compare(job.lease_expires_at, DateTime.add(soon, 30)) == :gt
      assert job.log_tail == "runner log line"
      assert length(comments(ctx.card)) == length(before)

      # The latest one wins.
      agent_conn(ctx.user, ctx.job.id)
      |> post(~p"/api/jobs/#{ctx.job.id}/progress", %{"step" => "tests passed: 412, failed: 0"})
      |> json_response(200)

      conn = conn_as(ctx.user) |> put_req_header("accept", "application/json")

      shown = conn |> get(~p"/api/jobs/#{ctx.job.id}") |> json_response(200)
      shown = shown["job"] || shown
      assert shown["step"] == "tests passed: 412, failed: 0"
      assert shown["step_at"]

      %{"jobs" => listed} =
        conn |> get(~p"/api/boards/#{ctx.board.id}/jobs") |> json_response(200)

      assert Enum.find(listed, &(&1["id"] == ctx.job.id))["step"] ==
               "tests passed: 412, failed: 0"

      %{"jobs" => on_card} = conn |> get(~p"/api/cards/#{ctx.card.id}/jobs") |> json_response(200)
      assert hd(on_card)["step"] == "tests passed: 412, failed: 0"

      assert length(comments(ctx.card)) == length(before)
    end

    test "a long step is cut to 300 characters", ctx do
      agent_conn(ctx.user, ctx.job.id)
      |> post(~p"/api/jobs/#{ctx.job.id}/progress", %{"step" => String.duplicate("a", 400)})
      |> json_response(200)

      assert String.length(Repo.get!(Job, ctx.job.id).step) == 300
    end

    test "a note is still a comment, as for a session", ctx do
      agent_conn(ctx.user, ctx.job.id)
      |> post(~p"/api/jobs/#{ctx.job.id}/progress", %{"note" => "Said on the card."})
      |> json_response(200)

      assert Enum.any?(comments(ctx.card), &(&1.body == "Said on the card."))
      assert Repo.get!(Job, ctx.job.id).log_tail == "runner log line"
    end

    test "is refused without the job's id, or naming another job", ctx do
      other_card = card_fixture(hd(ctx.board.columns), %{"title" => "Other"})
      {:ok, queued} = Runners.queue(other_card, %{pool: "elsewhere", kind: "claude", prompt: "x"})

      assert agent_conn(ctx.user, nil)
             |> post(~p"/api/jobs/#{ctx.job.id}/progress", %{"step" => "x"})
             |> json_response(403)

      assert agent_conn(ctx.user, queued.id)
             |> post(~p"/api/jobs/#{ctx.job.id}/progress", %{"step" => "x"})
             |> json_response(403)

      # A job no runner holds has nobody to report through.
      assert agent_conn(ctx.user, queued.id)
             |> post(~p"/api/jobs/#{queued.id}/progress", %{"step" => "x"})
             |> json_response(403)

      assert Repo.get!(Job, ctx.job.id).step == nil
    end

    test "on a job that has ended says cancel and keeps nothing", ctx do
      {:ok, _} = Runners.finish(ctx.runner, ctx.job.id, %{exit: "0"})

      assert %{"status" => "cancel"} =
               agent_conn(ctx.user, ctx.job.id)
               |> post(~p"/api/jobs/#{ctx.job.id}/progress", %{"step" => "late"})
               |> json_response(200)

      assert Repo.get!(Job, ctx.job.id).step == nil
    end
  end

  describe "the Runners panel" do
    test "shows the job's latest step against the runner, and in its details", ctx do
      {:ok, :ok} = Runners.heartbeat(ctx.runner, ctx.job.id, nil, step: "judging against the bar")

      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/automations")
      runner = ctx.runner

      assert has_element?(view, "#runner-#{runner.id}", "job ##{ctx.job.id}")
      assert has_element?(view, "#runner-#{runner.id}-step", "judging against the bar")

      view |> element("#show-runner-#{runner.id}") |> render_click()
      assert has_element?(view, "#runner-step-#{runner.id}", "judging against the bar")
    end

    test "shows no step for a job that hasn't given one", ctx do
      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/automations")
      assert has_element?(view, "#runner-#{ctx.runner.id}", "job ##{ctx.job.id}")
      refute has_element?(view, "#runner-#{ctx.runner.id}-step")
    end
  end
end
