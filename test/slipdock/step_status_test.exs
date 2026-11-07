defmodule Slipdock.StepStatusTest do
  @moduledoc """
  The server's step statuses (#2022): each agent step (a build job claimed,
  a rework, a wait opened, submitted and verifying, rejected, over the
  rejection limit, held, accepted and merging, merged, done, shipped) posts
  an On track status update with its step text and no user, never the same
  text twice in a row, and quietly: no activity line, so no watcher hears
  of it, while a person's own update still does. A job ending on a card
  already accepted leaves no handoff.
  """
  use Slipdock.DataCase, async: false

  import Ecto.Query
  import Slipdock.Fixtures

  alias Slipdock.{Actor, Boards, Deployments, Repo, Runners, StepStatus, Verified}
  alias Slipdock.Boards.{Activity, Card, StatusUpdate}
  alias Slipdock.Runners.Runner

  @pr "https://github.com/acme/app/pull/7"

  setup do
    owner = user_fixture()
    board = board_fixture(%{"name" => "Steps", "code" => unique_code()}, owner: owner)
    [_backlog, todo, doing, _done] = board.columns
    card = card_fixture(doing, %{"title" => "Work"})
    {:ok, runner, _} = Runners.create_runner(board, %{"name" => "box", "pool" => "dev"})
    builder = %{Actor.unknown() | kind: "agent", via: "api", user_id: owner.id, agent: "builder"}
    checker = %{Actor.unknown() | kind: "agent", via: "api", user_id: owner.id, agent: "checker"}

    %{
      owner: owner,
      board: board,
      todo: todo,
      doing: doing,
      card: card,
      runner: runner,
      builder: builder,
      checker: checker
    }
  end

  defp steps(card) do
    Repo.all(
      from u in StatusUpdate,
        where: u.card_id == ^card.id,
        order_by: [asc: u.inserted_at, asc: u.id]
    )
  end

  defp bodies(card), do: Enum.map(steps(card), & &1.body)

  defp status_activity(card) do
    Repo.all(from a in Activity, where: a.card_id == ^card.id and a.kind == "status")
  end

  defp verify!(ctx, attrs \\ %{}) do
    {:ok, board} =
      Boards.update_board(ctx.board, Map.merge(%{"verify_work" => true}, attrs))

    board
  end

  defp submit(card, ctx) do
    {:ok, card} =
      Boards.update_card(
        Repo.get!(Card, card.id),
        %{"completed" => true, "evidence_pr" => @pr, "evidence_commit" => "abc1234"},
        actor: ctx.builder
      )

    card
  end

  defp claim(ctx, kind \\ "claude", pool \\ "dev") do
    {:ok, job} =
      Runners.queue(Repo.get!(Card, ctx.card.id), %{pool: pool, kind: kind, prompt: "x"})

    runner =
      if pool == ctx.runner.pool,
        do: ctx.runner,
        else:
          ctx.board
          |> Runners.create_runner(%{"name" => "r-#{pool}", "pool" => pool})
          |> elem(1)

    runner = if kind in ["verify", "merge"], do: Runners.report_kinds(runner, kind), else: runner
    assert %{id: id} = Runners.claim(runner)
    assert id == job.id
    {runner, job}
  end

  describe "a build job" do
    test "claimed: Writing code, on track, with no user", ctx do
      claim(ctx)

      assert [%StatusUpdate{health: "on_track", body: "Writing code", user_id: nil}] =
               steps(ctx.card)
    end

    test "claimed again after a rejection: Reworking after verify failed", ctx do
      verify!(ctx)
      card = submit(ctx.card, ctx)

      {:ok, _} =
        Verified.decide(card, "reject", %{"reason" => "bar 1: no"}, ctx.checker, ctx.owner)

      claim(ctx)

      assert bodies(ctx.card) == [
               "Waiting for human to accept",
               "Verify failed; queued for rework",
               "Reworking after verify failed"
             ]
    end

    test "a job ending on a merging card leaves no handoff; on an open one it does", ctx do
      {runner, job} = claim(ctx)

      Repo.update_all(from(c in Card, where: c.id == ^ctx.card.id),
        set: [verify_state: "merging"]
      )

      {:ok, _} = Runners.finish(runner, job.id, %{exit: "0", output: "I accepted it. All green."})
      assert Boards.current_handoff(Repo.get!(Card, ctx.card.id)) == nil

      other = card_fixture(ctx.doing, %{"title" => "Open"})
      {:ok, job} = Runners.queue(other, %{pool: "dev", kind: "claude", prompt: "x"})
      assert %{id: id} = Runners.claim(runner)
      assert id == job.id
      {:ok, _} = Runners.finish(runner, job.id, %{exit: "0", output: "Write the tests"})
      assert %{next_step: "Write the tests"} = Boards.current_handoff(other)
    end

    test "a job ending on an accepted card leaves no handoff either", ctx do
      {runner, job} = claim(ctx)

      Repo.update_all(from(c in Card, where: c.id == ^ctx.card.id),
        set: [verify_state: "accepted"]
      )

      {:ok, _} = Runners.finish(runner, job.id, %{exit: "0", output: "Accepting will merge it"})
      assert Boards.current_handoff(Repo.get!(Card, ctx.card.id)) == nil
    end
  end

  describe "waits" do
    test "an agent's wait: Waiting for human", ctx do
      {:ok, _} = Boards.open_wait(ctx.card, ctx.builder, %{"needs" => "Which region?"})
      assert bodies(ctx.card) == ["Waiting for human"]
    end

    test "over the rejection limit: Waiting for human (rejection limit)", ctx do
      verify!(ctx, %{"verify_rejection_limit" => 1})

      card =
        Enum.reduce(1..2, ctx.card, fn n, card ->
          card = submit(card, ctx)

          {:ok, card} =
            Verified.decide(card, "reject", %{"reason" => "bar #{n}: no"}, ctx.checker, ctx.owner)

          card
        end)

      assert Repo.get_by(Boards.Wait, card_id: card.id).purpose == "verify_limit"
      assert List.last(bodies(card)) == "Waiting for human (rejection limit)"
    end
  end

  describe "verification" do
    test "submitted with a verify pool: Verifying, and the verify job's claim says it once",
         ctx do
      verify!(ctx, %{"verify_pool" => "checkers"})
      submit(ctx.card, ctx)
      assert bodies(ctx.card) == ["Verifying"]

      runner = elem(Runners.create_runner(ctx.board, %{"name" => "v", "pool" => "checkers"}), 1)
      runner = Runners.report_kinds(runner, "verify")
      assert %{kind: "verify"} = Runners.claim(runner)
      # The no-repeat rule: still one.
      assert bodies(ctx.card) == ["Verifying"]
    end

    test "submitted with no pool: Waiting for human to accept", ctx do
      verify!(ctx)
      submit(ctx.card, ctx)
      assert bodies(ctx.card) == ["Waiting for human to accept"]
    end

    test "rejected: Verify failed; queued for rework", ctx do
      verify!(ctx)
      card = submit(ctx.card, ctx)

      {:ok, _} =
        Verified.decide(card, "reject", %{"reason" => "bar 1: no"}, ctx.checker, ctx.owner)

      assert List.last(bodies(card)) == "Verify failed; queued for rework"
    end

    test "accepted on a board that ships by push: Done", ctx do
      verify!(ctx)
      card = submit(ctx.card, ctx)
      {:ok, _} = Verified.decide(card, "accept", %{}, ctx.checker, ctx.owner)
      assert List.last(bodies(card)) == "Done"
    end

    test "accepted on a pull-request board: Accepted; merging, then Merged", ctx do
      verify!(ctx, %{"ship_via" => "pull_request"})
      {:ok, merger, _} = Runners.create_runner(ctx.board, %{"name" => "m", "pool" => "m"})
      merger = Runners.report_kinds(merger, "merge")

      Repo.update_all(from(r in Runner, where: r.id == ^merger.id),
        set: [last_seen_at: DateTime.utc_now(:second)]
      )

      card = submit(ctx.card, ctx)
      {:ok, merging} = Verified.decide(card, "accept", %{}, ctx.checker, ctx.owner)
      assert merging.verify_state == "merging"
      assert List.last(bodies(card)) == "Accepted; merging"

      {:ok, done} =
        Boards.update_card(merging, %{"completed" => true},
          actor: Actor.runner(nil, 1, "m"),
          verify_changes: [verify_state: "accepted", merge_sha: "def5678"]
        )

      assert done.completed
      assert List.last(bodies(card)) == "Merged"
    end

    test "held for a person: Waiting for human (held before merge), once", ctx do
      verify!(ctx, %{"ship_via" => "pull_request", "profiles" => true})
      {:ok, card} = Boards.update_card(ctx.card, %{"profile" => "schema"})
      card = submit(card, ctx)
      {:ok, held} = Verified.decide(card, "accept", %{}, ctx.checker, ctx.owner)
      assert held.verify_state == "held"

      # The hold and the wait it opens say the same: posted once.
      assert bodies(card) == [
               "Waiting for human to accept",
               "Waiting for human (held before merge)"
             ]
    end
  end

  describe "done, reopened, shipped" do
    test "completed on a board that doesn't verify: Done; reopened: Reopened", ctx do
      {:ok, card} = Boards.update_card(ctx.card, %{"completed" => true}, actor: ctx.builder)
      {:ok, _} = Boards.update_card(card, %{"completed" => false}, actor: Actor.web(ctx.owner))
      assert bodies(card) == ["Done", "Reopened"]
    end

    test "a succeeded deploy naming it: Shipped to <env>; a failed one or a backfill, nothing",
         ctx do
      {:ok, board} = Boards.update_board(ctx.board, %{"delivery_metrics" => true})
      at = ~U[2026-11-06 14:32:00.000000Z]

      deploy = fn status, source ->
        sha = :crypto.strong_rand_bytes(20) |> Base.encode16(case: :lower)

        {:ok, _} =
          Deployments.start(board, %{
            "environment" => "production",
            "sha" => sha,
            "status" => status,
            "source" => source,
            "started_at" => at,
            "finished_at" => at,
            "commits" => [%{"sha" => sha, "subject" => "feat ##{ctx.card.id}"}]
          })
      end

      # A person's own card, no agent on it: no step.
      deploy.("succeeded", "api")
      assert bodies(ctx.card) == []

      {:ok, _} = Runners.queue(ctx.card, %{pool: "dev", kind: "claude", prompt: "x"})
      deploy.("failed", "api")
      deploy.("succeeded", "backfill")
      assert bodies(ctx.card) == []

      deploy.("succeeded", "api")
      assert bodies(ctx.card) == ["Shipped to production"]
    end
  end

  describe "a person's own card" do
    test "completing, reopening and asking on it post no step", ctx do
      person = Actor.web(ctx.owner)
      {:ok, card} = Boards.update_card(ctx.card, %{"completed" => true}, actor: person)
      {:ok, card} = Boards.update_card(card, %{"completed" => false}, actor: person)
      {:ok, _} = Boards.open_wait(card, person, %{"needs" => "Which colour?"})
      assert bodies(card) == []
    end

    test "a move into Done with no actor posts none either", ctx do
      [_backlog, _todo, _doing, done] = ctx.board.columns
      :ok = Boards.move_card(ctx.card.id, done.id)
      assert Repo.get!(Card, ctx.card.id).completed
      assert bodies(ctx.card) == []
    end

    test "once a runner job was sent for it, its completion is a step", ctx do
      {:ok, _} = Runners.queue(ctx.card, %{pool: "dev", kind: "claude", prompt: "x"})
      {:ok, _} = Boards.update_card(ctx.card, %{"completed" => true}, actor: Actor.web(ctx.owner))
      assert bodies(ctx.card) == ["Done"]
    end
  end

  describe "the rules" do
    test "the same text twice in a row is posted once, but again after another", ctx do
      card = Repo.get!(Card, ctx.card.id)
      StepStatus.post(card, "Writing code")
      StepStatus.post(card, "Writing code")
      StepStatus.post(card, "Waiting for human")
      StepStatus.post(card, "Writing code")
      assert bodies(card) == ["Writing code", "Waiting for human", "Writing code"]
    end

    test "a step is quiet: no activity line; a person's update still writes one", ctx do
      card = Repo.get!(Card, ctx.card.id)
      StepStatus.post(card, "Writing code")
      assert status_activity(card) == []

      {:ok, update} =
        Boards.add_status_update(card, ctx.owner, %{"health" => "at_risk", "body" => "Slipping"})

      assert update.user_id == ctx.owner.id
      assert [%Activity{message: message}] = status_activity(card)
      assert message =~ "at risk: Slipping"
    end

    test "a person's update after a step isn't swallowed by the no-repeat rule", ctx do
      card = Repo.get!(Card, ctx.card.id)
      StepStatus.post(card, "Verifying")

      {:ok, _} =
        Boards.add_status_update(card, ctx.owner, %{"health" => "at_risk", "body" => "Hm"})

      StepStatus.post(card, "Verifying")
      assert bodies(card) == ["Verifying", "Hm", "Verifying"]
    end

    test "no step on a finished card's audit claim", ctx do
      Repo.update_all(from(c in Card, where: c.id == ^ctx.card.id),
        set: [completed: true, verify_state: "accepted"]
      )

      claim(ctx, "verify", "audit")
      assert bodies(ctx.card) == []
    end
  end

  test "Help's How work flows names every step status at its stage" do
    named = Enum.flat_map(SlipdockWeb.HelpLive.Flow.stages(), & &1.steps)

    assert Enum.sort(named) ==
             Enum.sort([StepStatus.shipped_text("production") | StepStatus.texts()])
  end
end
