defmodule SlipdockWeb.VerifiedMergeTest do
  @moduledoc """
  Ship by PR 4 (#1657): on a board that ships by pull request, accepting a
  card (from the panel, REST, MCP or `Verified.decide/5`) queues one merge
  job instead of completing it, routed with no setting; the merge finishing
  completes the card with the merge commit, a failed one sends it back with
  the reason; with no runner that can merge, the card says so and a person
  marks it merged by hand. Push boards are unchanged.
  """
  use SlipdockWeb.ConnCase, async: true

  import Ecto.Query
  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Accounts, Actor, Boards, Repo, Runners, Verified}
  alias Slipdock.Boards.Card
  alias Slipdock.Runners.Job

  @pr "https://github.com/acme/app/pull/7"
  @sha "abc1234def5678abc1234def5678abc1234def56"

  setup %{user: user} do
    board = board_fixture(%{"name" => "Merges", "code" => unique_code()}, owner: user)

    {:ok, board} =
      Boards.update_board(board, %{"verify_work" => true, "ship_via" => "pull_request"})

    [_backlog, todo, doing, done] = board.columns
    card = card_fixture(doing, %{"title" => "Work"})

    builder = %{Actor.unknown() | kind: "agent", via: "api", user_id: user.id, agent: "builder"}
    checker = %{Actor.unknown() | kind: "agent", via: "api", user_id: user.id, agent: "checker"}

    %{
      board: board,
      todo: todo,
      doing: doing,
      done: done,
      card: card,
      builder: builder,
      checker: checker
    }
  end

  defp submit(card, ctx) do
    {:ok, card} =
      Boards.update_card(
        Repo.get!(Card, card.id),
        %{"completed" => true, "evidence_pr" => @pr, "evidence_commit" => "abc1234"},
        actor: ctx.builder
      )

    assert card.verify_state == "pending"
    card
  end

  defp merger(ctx, pool \\ "dev", kinds \\ "claude,merge") do
    {:ok, runner, token} =
      Runners.create_runner(ctx.board, %{"name" => "m-#{pool}", "pool" => pool})

    {Runners.report_kinds(runner, kinds), token}
  end

  defp accept(card, ctx),
    do: Verified.decide(Repo.get!(Card, card.id), "accept", %{}, ctx.checker, ctx.user)

  defp merge_jobs(card),
    do: Repo.all(from(j in Job, where: j.card_id == ^card.id and j.kind == "merge"))

  defp comments(card),
    do: Repo.all(from(c in Boards.Comment, where: c.card_id == ^card.id, select: c.body))

  defp api(user, label) do
    {token, _} = Accounts.create_api_token(user, label)

    build_conn()
    |> put_req_header("accept", "application/json")
    |> put_req_header("authorization", "Bearer " <> token)
  end

  describe "accepting" do
    test "queues one merge job and leaves the card merging, in progress", ctx do
      {_runner, _} = merger(ctx)
      card = submit(ctx.card, ctx)

      {:ok, card} = accept(card, ctx)

      assert card.verify_state == "merging"
      refute card.completed
      refute "review" in card.flags
      assert card.column_id == ctx.doing.id
      assert [%Job{pool: "dev", status: "queued"} = job] = merge_jobs(card)
      assert Runners.merge_target(job) == %{pr: @pr, commit: "abc1234"}
      assert Verified.merge_status(card) == :queued
      assert Enum.any?(comments(card), &(&1 =~ "merging #{@pr}"))
    end

    test "over REST and MCP verify_card the same", ctx do
      {_runner, _} = merger(ctx)
      card = submit(ctx.card, ctx)

      ctx.user
      |> api("rest-checker")
      |> post(~p"/api/cards/#{card.id}/verify", %{"decision" => "accept"})
      |> json_response(200)

      assert Repo.get!(Card, card.id).verify_state == "merging"
      assert length(merge_jobs(card)) == 1

      other = card_fixture(ctx.doing, %{"title" => "Other"}) |> submit(ctx)

      ctx.user
      |> api("mcp-checker")
      |> put_req_header("content-type", "application/json")
      |> post(
        "/mcp",
        Jason.encode!(%{
          jsonrpc: "2.0",
          id: 1,
          method: "tools/call",
          params: %{name: "verify_card", arguments: %{card: other.id, decision: "accept"}}
        })
      )
      |> json_response(200)

      assert Repo.get!(Card, other.id).verify_state == "merging"
      assert length(merge_jobs(other)) == 1
    end

    test "from the card panel, as a person", ctx do
      {_runner, _} = merger(ctx)
      card = submit(ctx.card, ctx)

      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/cards/#{card}")
      view |> element("#verify-accept") |> render_click()

      assert Repo.get!(Card, card.id).verify_state == "merging"
      assert length(merge_jobs(card)) == 1
      assert has_element?(view, "#card-merging", "A runner is merging")
      assert has_element?(view, "#verify-merged")
    end

    test "on a push board accepting completes the card as before, with no merge job", ctx do
      {:ok, board} = Boards.update_board(ctx.board, %{"ship_via" => "push"})
      {_runner, _} = merger(%{ctx | board: board})
      card = submit(ctx.card, ctx)

      {:ok, card} = accept(card, ctx)

      assert card.verify_state == "accepted"
      assert card.completed
      assert card.column_id == ctx.done.id
      assert merge_jobs(card) == []
    end
  end

  describe "routing, with no setting" do
    test "the pool of the runner that built the card, when it takes merge jobs", ctx do
      {_any, _} = merger(ctx, "any")
      {builder_runner, _} = merger(ctx, "build")
      {:ok, built} = Runners.queue(ctx.card, %{pool: "build", kind: "claude", prompt: "go"})
      %{id: id} = Runners.claim(builder_runner)
      assert id == built.id
      {:ok, _} = Runners.finish(builder_runner, id, %{exit: "0"})

      card = submit(ctx.card, ctx)
      assert Verified.merge_pool(card) == "build"
      {:ok, _} = accept(card, ctx)
      assert [%Job{pool: "build"}] = merge_jobs(card)
    end

    test "else any pool with a runner that takes merge jobs; older runners never", ctx do
      {builder_runner, _} = merger(ctx, "build", "claude")
      {:ok, _old, _} = Runners.create_runner(ctx.board, %{"name" => "old", "pool" => "old"})
      {_other, _} = merger(ctx, "other")
      {:ok, built} = Runners.queue(ctx.card, %{pool: "build", kind: "claude", prompt: "go"})
      %{id: id} = Runners.claim(builder_runner)
      assert id == built.id

      assert ctx.card |> submit(ctx) |> Verified.merge_pool() == "other"
    end

    test "with none that can, no job: the card and the panel say so", ctx do
      {_old, _} = merger(ctx, "dev", "claude")
      card = submit(ctx.card, ctx)

      {:ok, card} = accept(card, ctx)

      assert card.verify_state == "merging"
      assert merge_jobs(card) == []
      assert Verified.merge_status(card) == :none
      assert Enum.any?(comments(card), &(&1 =~ "**No runner can merge this.**"))
      assert Enum.any?(comments(card), &(&1 =~ "slipdock verify #{card.id} merged"))

      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/cards/#{card}")
      assert has_element?(view, "#card-no-merger")
      refute has_element?(view, "#card-merge-already-merged")
      refute has_element?(view, "#card-merge-waiting")
    end
  end

  describe "the merge job ending" do
    setup ctx do
      {runner, _} = merger(ctx)
      card = submit(ctx.card, ctx)
      {:ok, _} = accept(card, ctx)
      %{id: id} = Runners.claim(runner)
      %{runner: runner, merging: Repo.get!(Card, card.id), job_id: id}
    end

    test "done with a merge commit completes the card with it, in Done", ctx do
      {:ok, _} = Runners.finish(ctx.runner, ctx.job_id, %{exit: "0", merged: @sha})

      card = Repo.get!(Card, ctx.merging.id)
      assert card.completed
      assert card.verify_state == "accepted"
      assert card.merge_sha == @sha
      assert card.column_id == ctx.done.id
      assert Enum.any?(comments(card), &(&1 =~ "**Merged** by runner m-dev as `#{@sha}`"))
      assert SlipdockWeb.API.JSON.card(Boards.get_card!(card.id)).merge_sha == @sha
    end

    test "failed sends it back to the top of To Do with the reason, for rework", ctx do
      {:ok, _} =
        Runners.finish(ctx.runner, ctx.job_id, %{
          exit: "2",
          output: "checking\nmerge: #{@pr}'s head is 999, not the accepted commit abc1234\n"
        })

      card = Repo.get!(Card, ctx.merging.id)
      refute card.completed
      assert card.verify_state == "rejected"
      assert card.verify_note =~ "Merge failed (job ##{ctx.job_id}, failed)"
      assert card.verify_note =~ "not the accepted commit abc1234"
      assert card.evidence_pr == nil
      assert card.column_id == ctx.todo.id
      assert card.position == 0
      assert Verified.rejection(card).reason =~ "Merge failed"
      assert Boards.get_card!(card.id).handoff.next_step =~ "Rework: the merge failed"
      assert Enum.any?(comments(card), &(&1 =~ "rebase `card-#{card.id}` on the default branch"))
    end

    # #1666: the reason is the job's own words, and a rebase is suggested
    # only for a conflict or a head that moved.
    test "a failure a rebase won't fix says the job's reason and no rebase", ctx do
      # A runner that can't merge here hands the merge on instead (#1754):
      # this failure is the card's.
      said = "merge: #{@pr} is CLOSED, not open; nothing merged"
      {:ok, _} = Runners.finish(ctx.runner, ctx.job_id, %{exit: "2", output: "x\n#{said}\n"})

      card = Repo.get!(Card, ctx.merging.id)
      assert card.verify_note == "Merge failed (job ##{ctx.job_id}, failed): #{said}"
      assert [failed] = Enum.filter(comments(card), &(&1 =~ "**Merge failed.**"))
      assert failed =~ said
      assert failed =~ "a rebase won't fix it"
      refute failed =~ ~r/rebase `/i
    end

    test "a conflict says gh's reason and suggests rebasing the branch", ctx do
      said =
        "merge: gh pr merge refused #{@pr}: X Pull request acme/app#7 is not mergeable: " <>
          "the merge commit cannot be cleanly created."

      {:ok, _} = Runners.finish(ctx.runner, ctx.job_id, %{exit: "3", output: said})

      card = Repo.get!(Card, ctx.merging.id)
      assert card.verify_note =~ "cannot be cleanly created"
      assert [failed] = Enum.filter(comments(card), &(&1 =~ "**Merge failed.**"))
      assert failed =~ "rebase `card-#{card.id}` on the default branch"
      assert failed =~ said
    end

    # #2637: a pull request somebody merged before the job got to it.
    test "already merged at the accepted commit completes the card as merged", ctx do
      said = "merge: #{@pr} was already merged at the accepted commit (head abc1234ff) as #{@sha}"
      {:ok, _} = Runners.finish(ctx.runner, ctx.job_id, %{exit: "0", merged: @sha, output: said})

      card = Repo.get!(Card, ctx.merging.id)
      assert card.completed
      assert card.verify_state == "accepted"
      assert card.merge_sha == @sha
      assert card.column_id == ctx.done.id
      assert card.verify_rejections in [nil, 0]

      assert Enum.any?(
               comments(card),
               &(&1 =~
                   "**Merged** by runner m-dev: the pull request was already merged at the " <>
                     "accepted commit as `#{@sha}`.")
             )

      quality = Slipdock.Quality.for_board(ctx.board)
      assert quality.verified.accepted == 1
      assert quality.verified.first_time_right == 1
      assert quality.verified.rejections == 0
    end

    test "already merged at another head fails, says which, and isn't a rejection", ctx do
      # A rejection before the acceptance: one more would be the circling second.
      Repo.update_all(from(c in Card, where: c.id == ^ctx.merging.id),
        set: [verify_rejections: 1]
      )

      said =
        "merge: #{@pr} was already merged at head 999fff, not the accepted commit abc1234; " <>
          "nothing merged"

      {:ok, _} = Runners.finish(ctx.runner, ctx.job_id, %{exit: "2", output: "x\n#{said}\n"})

      card = Repo.get!(Card, ctx.merging.id)
      refute card.completed
      assert card.verify_state == "merging"
      assert card.verify_rejections == 1
      assert card.evidence_pr == @pr
      assert card.column_id == ctx.merging.column_id
      assert Repo.get!(Job, ctx.job_id).status == "failed"
      refute Verified.Circling.circling?(card)
      assert Verified.merge_status(card) == :already_merged

      # The panel says what happened, not that no runner can merge (#2646).
      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/cards/#{card}")
      assert view |> element("#card-merge-already-merged") |> render() =~ "already merged"
      refute has_element?(view, "#card-no-merger")
      refute has_element?(view, "#card-merge-waiting")

      all = comments(card)
      assert [failed] = Enum.filter(all, &(&1 =~ "**Merge failed: already merged.**"))
      assert failed =~ "head 999fff, not the accepted commit abc1234"
      assert failed =~ "doesn't count as a rejection"
      assert failed =~ "slipdock verify #{card.id} merged"
      refute Enum.any?(all, &(&1 =~ "Going round in circles"))
      refute Enum.any?(all, &(&1 =~ "**Merge failed.**"))

      quality = Slipdock.Quality.for_board(ctx.board)
      assert quality.verified.in_rework == 0
      assert quality.verified.rejections == 1

      # A person who checks it can still mark it merged by hand.
      {:ok, card} =
        Verified.decide(card, "merged", %{"commit" => "999fff1"}, Actor.web(ctx.user), ctx.user)

      assert card.completed
    end

    test "an older runner's 'is MERGED, not open' is treated the same", ctx do
      said = "merge: #{@pr} is MERGED, not open; nothing merged"
      {:ok, _} = Runners.finish(ctx.runner, ctx.job_id, %{exit: "2", output: said})

      card = Repo.get!(Card, ctx.merging.id)
      assert card.verify_state == "merging"
      assert card.verify_rejections in [nil, 0]
      assert Enum.any?(comments(card), &(&1 =~ "**Merge failed: already merged.**"))
      assert Verified.merge_status(card) == :already_merged
    end

    test "a runner that can't merge here, with none to hand on to: the panel says it waits",
         ctx do
      said =
        "merge: the pull request is in acme/app, but this runner's repository is " <>
          "https://github.com/other/thing.git; nothing merged"

      {:ok, _} = Runners.finish(ctx.runner, ctx.job_id, %{exit: "2", output: said})

      card = Repo.get!(Card, ctx.merging.id)
      assert card.verify_state == "merging"
      assert Enum.any?(comments(card), &(&1 =~ "**Merge waiting.**"))
      assert Verified.merge_status(card) == :waiting

      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/cards/#{card}")
      assert view |> element("#card-merge-waiting") |> render() =~ "no other runner"
      refute has_element?(view, "#card-no-merger")
      refute has_element?(view, "#card-merge-already-merged")
    end

    test "a merge job that failed some other way leaves no reason to give", ctx do
      # A failure merge_finished/2 sends back is no longer merging; one that
      # somehow left the card merging is read as nothing to merge it.
      {:ok, _} =
        Runners.finish(ctx.runner, ctx.job_id, %{exit: "1", output: "merge: something else"})

      card = %{
        Repo.get!(Card, ctx.merging.id)
        | verify_state: "merging",
          verify_at: ctx.merging.verify_at
      }

      assert Verified.merge_status(card) == :none
    end

    test "a merge job from before the acceptance doesn't count (#2646)", ctx do
      said = "merge: #{@pr} was already merged at head 999fff, not the accepted commit abc1234"
      {:ok, _} = Runners.finish(ctx.runner, ctx.job_id, %{exit: "2", output: said})

      later = DateTime.utc_now() |> DateTime.add(3600) |> DateTime.truncate(:second)
      Repo.update_all(from(c in Card, where: c.id == ^ctx.merging.id), set: [verify_at: later])

      assert Verified.merge_status(Repo.get!(Card, ctx.merging.id)) == :none
    end

    # Only the runner's own `merge:` line says it was already merged: the
    # same words elsewhere in a failed job's output (a shell runner's last
    # line, say) are a failure like any other.
    for said <- [
          "gh: acme/app#7 is MERGED, not open",
          "note: it was already merged at head 999fff"
        ] do
      test "#{said} without a merge: line is a failed merge, rejected", ctx do
        {:ok, _} =
          Runners.finish(ctx.runner, ctx.job_id, %{exit: "1", output: "x\n#{unquote(said)}\n"})

        card = Repo.get!(Card, ctx.merging.id)
        refute card.completed
        assert card.verify_state == "rejected"
        assert card.verify_rejections == 1
        assert card.verify_note =~ unquote(said)
        assert card.column_id == ctx.todo.id
        all = comments(card)
        assert Enum.any?(all, &(&1 =~ "**Merge failed.**"))
        refute Enum.any?(all, &(&1 =~ "**Merge failed: already merged.**"))
      end
    end

    test "a person cancelling it sends it back too", ctx do
      job = Repo.get!(Job, ctx.job_id)
      {:ok, _} = Runners.cancel_job(job)
      {:ok, _} = Runners.finish(ctx.runner, ctx.job_id, %{exit: "130", status: "cancelled"})

      card = Repo.get!(Card, ctx.merging.id)
      assert card.verify_state == "rejected"
      assert card.verify_note =~ "cancelled"
    end
  end

  describe "which failures a rebase fixes" do
    test "a conflict or a moved head, nothing else" do
      assert Verified.rebase_fixes?(
               "merge: gh pr merge refused x: merge conflict between base and head"
             )

      assert Verified.rebase_fixes?(
               "merge: x's head is 9, not the accepted commit abc (it moved after the card was accepted)"
             )

      assert Verified.rebase_fixes?(
               "merge: gh pr merge refused x: Head branch was modified. Review and try the merge again."
             )

      assert Verified.rebase_fixes?(
               "merge: gh pr merge refused x: Head branch is not up to date with the base branch"
             )

      refute Verified.rebase_fixes?("merge: /srv/app has no origin remote")
      refute Verified.rebase_fixes?("merge: gh is not signed in (run gh auth login)")
      refute Verified.rebase_fixes?("merge: gh pr merge refused x: gh gave no reason")
      refute Verified.rebase_fixes?("merge: x is CLOSED, not open; nothing merged")
      refute Verified.rebase_fixes?(nil)
    end
  end

  # #1666: the verifier's CLI or MCP token is the builder's too, so a
  # decision made in a runner job names the runner, as the merge does.
  describe "a decision made in a runner job" do
    setup ctx do
      {:ok, runner, _} = Runners.create_runner(ctx.board, %{"name" => "verifier", "pool" => "v"})
      Runners.report_kinds(runner, "verify")
      card = submit(ctx.card, ctx)
      {:ok, _} = Runners.queue(card, %{pool: "v", kind: "verify", prompt: "check it"})
      %{id: job_id} = Runners.claim(runner)
      %{verifying: card, verify_job: job_id}
    end

    test "is credited to the runner, on the comment and the stored decision", ctx do
      in_job = %{ctx.checker | via: "cli", agent: "slipdock CLI on box", job_id: ctx.verify_job}

      {:ok, card} =
        Verified.decide(
          ctx.verifying,
          "reject",
          %{"reason" => "bar 1: no tests"},
          in_job,
          ctx.user
        )

      assert Enum.any?(comments(card), &(&1 =~ "**Rejected** by runner verifier."))
      refute Enum.any?(comments(card), &(&1 =~ "slipdock CLI on box"))
      assert Verified.who(card.verify_by) == "runner verifier"
      assert Verified.rejection(card).by == "runner verifier"
      assert card.verify_by["job_id"] == ctx.verify_job
    end

    test "an accept is credited the same way", ctx do
      in_job = %{ctx.checker | job_id: ctx.verify_job}
      {:ok, card} = Verified.decide(ctx.verifying, "accept", %{}, in_job, ctx.user)
      assert Enum.any?(comments(card), &(&1 =~ "**Accepted** by runner verifier; merging"))
    end

    test "over REST, from the job the CLI names", ctx do
      ctx.user
      |> api("slipdock CLI on box")
      |> put_req_header("x-slipdock-client", "cli")
      |> put_req_header("x-slipdock-agent", "1")
      |> put_req_header("x-slipdock-job", "#{ctx.verify_job}")
      |> post(~p"/api/cards/#{ctx.verifying.id}/verify", %{
        "decision" => "reject",
        "reason" => "bar 1: no"
      })
      |> json_response(200)

      assert Verified.who(Repo.get!(Card, ctx.verifying.id).verify_by) == "runner verifier"
    end

    test "a job on another card credits nobody but the token", ctx do
      other = card_fixture(ctx.doing, %{"title" => "Other"})
      {:ok, elsewhere} = Runners.queue(other, %{pool: "none", kind: "verify", prompt: "x"})
      in_job = %{ctx.checker | job_id: elsewhere.id}

      {:ok, card} =
        Verified.decide(ctx.verifying, "reject", %{"reason" => "bar 1: no"}, in_job, ctx.user)

      assert Enum.any?(comments(card), &(&1 =~ "**Rejected** by agent “checker”."))
    end

    test "no job is the token's label, as before", ctx do
      {:ok, card} =
        Verified.decide(
          ctx.verifying,
          "reject",
          %{"reason" => "bar 1: no"},
          ctx.checker,
          ctx.user
        )

      assert Verified.who(card.verify_by) == "agent “checker”"
    end
  end

  describe "Merged it myself" do
    test "a person completes a merging card, cancelling its merge job", ctx do
      {_runner, _} = merger(ctx)
      card = submit(ctx.card, ctx)
      {:ok, _} = accept(card, ctx)
      [job] = merge_jobs(card)

      {:ok, card} =
        Verified.decide(
          Repo.get!(Card, card.id),
          "merged",
          %{"commit" => "ABCDEF1"},
          Actor.web(ctx.user),
          ctx.user
        )

      assert card.completed
      assert card.verify_state == "accepted"
      assert card.merge_sha == "abcdef1"
      assert card.column_id == ctx.done.id
      assert Repo.get!(Job, job.id).status == "cancelled"
      assert Enum.any?(comments(card), &(&1 =~ "**Merged by hand**"))
    end

    test "from the panel, with no runner to merge", ctx do
      card = submit(ctx.card, ctx)
      {:ok, _} = accept(card, ctx)

      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/cards/#{card}")
      view |> element("#verify-merged") |> render_click()

      card = Repo.get!(Card, card.id)
      assert card.completed
      assert card.merge_sha == nil
    end

    test "not by an agent, not on a card that isn't merging, and only a commit id", ctx do
      card = submit(ctx.card, ctx)

      assert {:error, :conflict, _} =
               Verified.decide(card, "merged", %{}, Actor.web(ctx.user), ctx.user)

      {:ok, card} = accept(card, ctx)

      assert {:error, :forbidden, _} = Verified.decide(card, "merged", %{}, ctx.checker, ctx.user)

      assert {:error, :unprocessable_entity, _} =
               Verified.decide(
                 card,
                 "merged",
                 %{"commit" => "nope"},
                 Actor.web(ctx.user),
                 ctx.user
               )

      refute Repo.get!(Card, card.id).completed
    end
  end
end
