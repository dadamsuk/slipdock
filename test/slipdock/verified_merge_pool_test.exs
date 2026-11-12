defmodule Slipdock.VerifiedMergePoolTest do
  @moduledoc """
  Merges don't wait behind the pass (#1754): an accepted card's merge goes
  to a runner that is idle now, the builder's pool first, else to the
  runner that decided it (about to finish its verify job), else as before.
  A runner that can't merge here hands the merge on rather than sending the
  card back, a bounded number of times.
  """
  use Slipdock.DataCase, async: true

  import Ecto.Query
  import Slipdock.Fixtures

  alias Slipdock.{Actor, Boards, Repo, Runners, Verified}
  alias Slipdock.Boards.Card
  alias Slipdock.Runners.{Job, Runner}

  @pr "https://github.com/acme/app/pull/7"
  @wrong_repo "merge: the pull request is in acme/app, but this runner's repository is " <>
                "https://github.com/other/thing.git; nothing merged"

  setup do
    owner = user_fixture()
    board = board_fixture(%{"name" => "Merge pool", "code" => unique_code()}, owner: owner)

    {:ok, board} =
      Boards.update_board(board, %{"verify_work" => true, "ship_via" => "pull_request"})

    [_backlog, todo, doing, _done] = board.columns
    card = card_fixture(doing, %{"title" => "Work"})
    builder = %{Actor.unknown() | kind: "agent", via: "api", user_id: owner.id, agent: "builder"}
    checker = %{Actor.unknown() | kind: "agent", via: "api", user_id: owner.id, agent: "checker"}

    %{owner: owner, board: board, todo: todo, card: card, builder: builder, checker: checker}
  end

  # A runner on the board that says it takes `kinds`, seen `ago` seconds ago.
  defp runner(ctx, name, pool, kinds, ago \\ 0) do
    {:ok, runner, _} = Runners.create_runner(ctx.board, %{"name" => name, "pool" => pool})
    runner = Runners.report_kinds(runner, kinds)
    seen = DateTime.utc_now() |> DateTime.add(-ago) |> DateTime.truncate(:second)
    Repo.update_all(from(r in Runner, where: r.id == ^runner.id), set: [last_seen_at: seen])
    Repo.get!(Runner, runner.id)
  end

  # `runner` takes a job of `kind` on the card and keeps it: busy.
  defp busy(runner, card, kind \\ "claude") do
    {:ok, job} = Runners.queue(card, %{pool: runner.pool, kind: kind, prompt: "go"})
    %Job{id: id} = Runners.claim(runner)
    assert id == job.id
    job
  end

  defp submit(card, ctx) do
    {:ok, card} =
      Boards.Cards.update_card(
        Repo.get!(Card, card.id),
        %{"completed" => true, "evidence_pr" => @pr, "evidence_commit" => "abc1234"},
        actor: ctx.builder
      )

    assert card.verify_state == "pending"
    card
  end

  defp accept(card, actor, ctx),
    do: Verified.decide(Repo.get!(Card, card.id), "accept", %{}, actor, ctx.owner)

  defp merge_jobs(card),
    do:
      Repo.all(from(j in Job, where: j.card_id == ^card.id and j.kind == "merge", order_by: j.id))

  defp comments(card),
    do: Repo.all(from(c in Boards.Comment, where: c.card_id == ^card.id, select: c.body))

  describe "Runners.idle?/1" do
    test "seen lately and holding no job; not when busy, long unseen or never seen", ctx do
      idle = runner(ctx, "idle", "a", "merge")
      assert Runners.idle?(idle)

      gone = runner(ctx, "gone", "b", "merge", 3600)
      refute Runners.idle?(gone)

      {:ok, never, _} = Runners.create_runner(ctx.board, %{"name" => "never", "pool" => "c"})
      refute Runners.idle?(never)

      busy(idle, ctx.card)
      refute Runners.idle?(Repo.get!(Runner, idle.id))
    end
  end

  describe "where the merge goes" do
    test "to an idle runner that merges, while the builder's runner is busy", ctx do
      loop = runner(ctx, "loop", "loop", "claude,merge")
      _verifier = runner(ctx, "verifier", "verify", "verify,merge")
      busy(loop, ctx.card)
      card = submit(ctx.card, ctx)

      assert Verified.merge_pool(card) == "verify"
      {:ok, _} = accept(card, ctx.checker, ctx)
      assert [%Job{pool: "verify", exclude_runner_id: nil}] = merge_jobs(card)
    end

    test "to the builder's pool first when it is idle too", ctx do
      loop = runner(ctx, "loop", "loop", "claude,merge")
      _verifier = runner(ctx, "verifier", "verify", "verify,merge")
      job = busy(loop, ctx.card)
      {:ok, _} = Runners.finish(loop, job.id, %{exit: "0"})

      assert ctx.card |> submit(ctx) |> Verified.merge_pool() == "loop"
    end

    test "to the builder's pool even when another idle runner was seen more recently", ctx do
      loop = runner(ctx, "loop", "loop", "claude,merge")
      verifier = runner(ctx, "verifier", "verify", "verify,merge")
      job = busy(loop, ctx.card)
      {:ok, _} = Runners.finish(loop, job.id, %{exit: "0"})

      # The candidates come most recently seen first, so the verifier's pool
      # heads the idle ones: only the builder-first rule picks "loop" here.
      seen = DateTime.utc_now() |> DateTime.add(-10) |> DateTime.truncate(:second)
      Repo.update_all(from(r in Runner, where: r.id == ^loop.id), set: [last_seen_at: seen])

      Repo.update_all(from(r in Runner, where: r.id == ^verifier.id),
        set: [last_seen_at: DateTime.add(seen, 10)]
      )

      assert Runners.idle?(Repo.get!(Runner, loop.id))
      assert Runners.idle?(Repo.get!(Runner, verifier.id))

      card = submit(ctx.card, ctx)
      assert Verified.merge_pool(card) == "loop"

      # With no builder to prefer, the same two runners give the other pool.
      other = card_fixture(ctx.todo, %{"title" => "Nobody built this"})
      assert Verified.merge_pool(other) == "verify"
    end

    test "with none idle, to the runner that decided it, in its verify job", ctx do
      loop = runner(ctx, "loop", "loop", "claude,merge")
      verifier = runner(ctx, "verifier", "verify", "verify,merge")
      busy(loop, ctx.card)
      card = submit(ctx.card, ctx)
      verify_job = busy(verifier, card, "verify")

      # Without a decider it waits for the builder's pool, as before.
      assert Verified.merge_pool(card) == "loop"
      assert Verified.merge_pool(card, decider: verifier.id) == "verify"

      in_job = %{ctx.checker | job_id: verify_job.id}
      {:ok, card} = accept(card, in_job, ctx)
      assert card.verify_state == "merging"
      assert [%Job{pool: "verify"}] = merge_jobs(card)
    end

    test "a decider that doesn't merge, or a person, changes nothing", ctx do
      loop = runner(ctx, "loop", "loop", "claude,merge")
      checker = runner(ctx, "checker", "verify", "verify")
      busy(loop, ctx.card)
      card = submit(ctx.card, ctx)
      verify_job = busy(checker, card, "verify")

      assert Verified.merge_pool(card, decider: checker.id) == "loop"

      {:ok, _} = accept(card, %{ctx.checker | job_id: verify_job.id}, ctx)
      assert [%Job{pool: "loop"}] = merge_jobs(card)
    end

    test "a runner not seen lately isn't idle: the builder's pool, as before", ctx do
      loop = runner(ctx, "loop", "loop", "claude,merge")
      _away = runner(ctx, "away", "verify", "verify,merge", 3600)
      busy(loop, ctx.card)

      assert ctx.card |> submit(ctx) |> Verified.merge_pool() == "loop"
    end
  end

  describe "a runner that can't merge here" do
    setup ctx do
      a = runner(ctx, "a", "pa", "merge")
      b = runner(ctx, "b", "pb", "merge")
      card = submit(ctx.card, ctx)
      {:ok, card} = accept(card, ctx.checker, ctx)
      %{a: a, b: b, merging: card}
    end

    # Claims the open merge job with whichever of `runners` it goes to, and
    # finishes it with the runner script's refusal.
    defp refuse(runners, said) do
      job = Enum.find_value(runners, &Runners.claim(Repo.get!(Runner, &1.id)))
      assert %Job{kind: "merge"} = job

      {:ok, _} =
        Runners.finish(Repo.get!(Runner, job.runner_id), job.id, %{
          exit: "2",
          output: "checking\n#{said}\n"
        })

      job
    end

    for said <- [
          @wrong_repo,
          "merge: /srv/app has no origin remote",
          "merge: git is not installed",
          "merge: gh (GitHub CLI) is not installed",
          "merge: gh is not signed in (run gh auth login)"
        ] do
      test "hands it on, leaving that runner out: #{String.slice(said, 0, 40)}", ctx do
        first = refuse([ctx.a, ctx.b], unquote(said))

        card = Repo.get!(Card, ctx.merging.id)
        assert card.verify_state == "merging"
        refute card.completed
        assert Verified.rejection(card) == nil

        assert [_, %Job{status: "queued", exclude_runner_id: excluded} = next] = merge_jobs(card)
        assert excluded == first.runner_id
        other = if first.runner_id == ctx.a.id, do: ctx.b, else: ctx.a
        assert next.pool == other.pool

        assert [handed] = Enum.filter(comments(card), &(&1 =~ "**Merge handed on.**"))
        assert handed =~ "pool `#{other.pool}` has it now"
        assert handed =~ unquote(said)
      end
    end

    test "the runner it was taken from can't claim it back", ctx do
      first = refuse([ctx.a, ctx.b], @wrong_repo)
      refuser = Repo.get!(Runner, first.runner_id)
      assert Runners.claim(refuser) == nil
    end

    test "after two hand-ons the card waits, merging, with nothing queued and says why", ctx do
      for _ <- 1..3, do: refuse([ctx.a, ctx.b], @wrong_repo)

      card = Repo.get!(Card, ctx.merging.id)
      assert card.verify_state == "merging"
      assert Verified.rejection(card) == nil
      assert Enum.all?(merge_jobs(card), &(&1.status == "failed"))
      assert length(merge_jobs(card)) == 3
      assert Verified.merge_status(card) == :waiting

      assert [waiting] = Enum.filter(comments(card), &(&1 =~ "**Merge waiting.**"))
      assert waiting =~ "slipdock verify #{card.id} merged"
      assert length(Enum.filter(comments(card), &(&1 =~ "**Merge handed on.**"))) == 2
    end

    test "a failure that is the card's still sends it back for rework", ctx do
      refuse([ctx.a, ctx.b], "merge: #{@pr}'s head is 999, not the accepted commit abc1234")

      card = Repo.get!(Card, ctx.merging.id)
      assert card.verify_state == "rejected"
      assert card.verify_note =~ "not the accepted commit abc1234"
      assert card.column_id == ctx.todo.id
    end
  end

  test "with no other runner that merges, a refusal waits at once", ctx do
    only = runner(ctx, "only", "solo", "merge")
    card = submit(ctx.card, ctx)
    {:ok, _} = accept(card, ctx.checker, ctx)
    %Job{id: id} = Runners.claim(only)
    {:ok, _} = Runners.finish(only, id, %{exit: "2", output: @wrong_repo})

    card = Repo.get!(Card, card.id)
    assert card.verify_state == "merging"
    assert [%Job{status: "failed"}] = merge_jobs(card)
    assert Enum.any?(comments(card), &(&1 =~ "**Merge waiting.**"))
    refute Enum.any?(comments(card), &(&1 =~ "No runner can merge this"))
  end
end
