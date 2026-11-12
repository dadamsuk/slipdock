defmodule Slipdock.CardStateEpicJobTest do
  @moduledoc """
  A subcard worked inside its epic's job (#2899): the epic's job holds the
  epic and builds its subcards one by one, saying which in its step
  (`#2835 CI running`). The subcard it names shows that job's runner and
  kind as its loop and its state as running, and isn't "nobody on it" on
  the epic's blocker line; a sibling the step doesn't name stays as it was.
  """
  use Slipdock.DataCase, async: true

  import Ecto.Query
  import Slipdock.Fixtures

  alias Slipdock.{Boards, CardState, Repo, Runners, Work}
  alias Slipdock.Boards.CardMove
  alias Slipdock.Runners.Job
  alias Slipdock.Work.Tree

  setup do
    owner = user_fixture("epic-job-owner@example.com")
    board = board_fixture(%{"name" => "Epic jobs"}, owner: owner)
    [_backlog, _todo, doing, _done] = board.columns
    {:ok, runner, _} = Runners.create_runner(board, %{"name" => "dedev", "pool" => "dev"})

    epic = card_fixture(doing, %{"title" => "Epic"})
    {:ok, t} = Boards.Templates.find_template(nil, "Simple")
    {:ok, sub} = sub_board(epic, t)
    sub = Boards.get_board!(sub.id)
    sub_doing = Enum.find(sub.columns, &(&1.name == "Doing"))

    named = card_fixture(sub_doing, %{"title" => "Named"})
    sibling = card_fixture(sub_doing, %{"title" => "Sibling"})

    %{
      owner: owner,
      board: board,
      runner: runner,
      epic: epic,
      sub: sub,
      sub_doing: sub_doing,
      named: named,
      sibling: sibling
    }
  end

  # The epic's job, claimed by the runner and reporting `step`.
  defp epic_job(ctx, step, card \\ nil) do
    {:ok, _} = Runners.queue(card || ctx.epic, %{pool: "dev", kind: "claude", prompt: "go"})
    job = Runners.claim(ctx.runner)
    {:ok, :ok} = Runners.heartbeat(ctx.runner, job.id, nil, step: step)
    Repo.get!(Job, job.id)
  end

  defp state_of(board, card) do
    board
    |> Boards.Cards.list_cards(%{})
    |> Enum.find(&(&1.id == card.id))
    |> Map.fetch!(:state)
  end

  # Puts the card's ledger entry into its list two hours ago: past the hour
  # a card may sit in progress with nobody on it.
  defp entered_long_ago(card) do
    at = DateTime.add(DateTime.utc_now(), -7200, :second)
    from(m in CardMove, where: m.card_id == ^card.id) |> Repo.update_all(set: [inserted_at: at])
  end

  describe "the subcard's loop and state" do
    test "the subcard the step names shows the epic's runner and kind, and reads running", ctx do
      job = epic_job(ctx, "##{ctx.named.id} CI running")

      state = state_of(ctx.sub, ctx.named)
      assert state.loop == %{runner: "dedev", kind: "build", job_id: job.id}
      assert state.kind == "running"
      assert state.line =~ ~r/^Running · dedev · .* · in ##{ctx.epic.id}$/
      assert state.driver == "agent"
    end

    test "a sibling the step doesn't name has no loop and no line", ctx do
      epic_job(ctx, "##{ctx.named.id} CI running")

      state = state_of(ctx.sub, ctx.sibling)
      assert state.loop == nil
      assert state.kind == nil
      assert state.line == nil
    end

    test "the epic's own state is its own job's, with no 'in'", ctx do
      job = epic_job(ctx, "##{ctx.named.id} CI running")

      state = state_of(ctx.board, ctx.epic)
      assert state.loop.job_id == job.id
      refute state.line =~ " · in #"
    end

    test "a card named in a job's step that isn't above it is not worked by it", ctx do
      other = card_fixture(hd(ctx.board.columns), %{"title" => "Elsewhere"})
      epic_job(ctx, "##{ctx.named.id} CI running", other)

      assert state_of(ctx.sub, ctx.named).loop == nil
      assert CardState.epic_jobs([ctx.named.id]) == %{}
    end

    test "a completed subcard the step still names shows no loop", ctx do
      epic_job(ctx, "##{ctx.named.id} merged")
      {:ok, done} = Boards.Cards.update_card(ctx.named, %{"completed" => true})

      assert state_of(ctx.sub, done).loop == nil
      assert CardState.epic_jobs([done.id]) == %{}
    end

    test "the subcard's own open job wins over its epic's", ctx do
      epic_job(ctx, "##{ctx.named.id} CI running")
      {:ok, own} = Runners.queue(ctx.named, %{pool: "dev", kind: "claude", prompt: "go"})

      state = state_of(ctx.sub, ctx.named)
      # Its own queued job (held here, behind the epic in progress), not
      # the epic's running one.
      assert state.kind in ~w(queued held)
      assert state.loop == nil
      refute state.line =~ " · in #"
      assert own.status == "queued"
    end

    test "once the epic's job ends the subcard has no loop", ctx do
      job = epic_job(ctx, "##{ctx.named.id} CI running")
      Repo.update_all(from(j in Job, where: j.id == ^job.id), set: [status: "done"])

      assert state_of(ctx.sub, ctx.named).loop == nil
    end

    test "a verify job's step naming a subcard is not building it", ctx do
      {:ok, j} = Runners.queue(ctx.epic, %{pool: "dev", kind: "verify", prompt: "go"})
      job = Runners.claim(ctx.runner)
      assert job.id == j.id
      {:ok, :ok} = Runners.heartbeat(ctx.runner, job.id, nil, step: "checking ##{ctx.named.id}")

      assert CardState.epic_jobs([ctx.named.id]) == %{}
    end

    test "a job on an epic two levels up works a subcard's subcard", ctx do
      {:ok, t} = Boards.Templates.find_template(nil, "Simple")
      {:ok, deeper} = sub_board(ctx.named, t)
      deeper = Boards.get_board!(deeper.id)
      leaf = card_fixture(hd(deeper.columns), %{"title" => "Leaf"})
      job = epic_job(ctx, "##{leaf.id} starting")

      assert %{} = found = CardState.epic_jobs([leaf.id])
      assert found[leaf.id].id == job.id
      assert state_of(deeper, leaf).loop.job_id == job.id
    end

    test "loops/1 (the outline) and loop_of/2 (the card panel) see it too", ctx do
      job = epic_job(ctx, "##{ctx.named.id} CI running")

      assert CardState.loops([ctx.named.id, ctx.sibling.id]) == %{
               ctx.named.id => %{runner: "dedev", kind: "build", job_id: job.id}
             }

      assert CardState.loop_of(ctx.named, []).job_id == job.id
      assert CardState.loop_of(ctx.sibling, []) == nil
    end
  end

  describe "step_card_ids/1" do
    test "reads each #id once, in order, and not an anchor, an html entity or a non-ASCII digit" do
      assert CardState.step_card_ids("#2835 CI running") == [2835]
      assert CardState.step_card_ids("#2835 merged; starting #2836, then #2835") == [2835, 2836]
      assert CardState.step_card_ids("guide/setup.md#runners, &#39; and x#12") == []
      assert CardState.step_card_ids("#٣ and é#5") == []
      assert CardState.step_card_ids(nil) == []
    end
  end

  describe "the epic's blocker line" do
    test "the subcard the job is on isn't 'nobody on it'; its sibling still is", ctx do
      entered_long_ago(ctx.named)
      entered_long_ago(ctx.sibling)
      epic_job(ctx, "##{ctx.named.id} CI running")

      reasons = ctx.owner |> Work.waiting_on_me() |> Enum.map(&{&1.card.id, &1.reason})
      refute {ctx.named.id, "needs_owner"} in reasons
      assert {ctx.sibling.id, "needs_owner"} in reasons

      tree = Tree.for_board(ctx.owner, ctx.board)

      assert Tree.glance(Tree.of(tree, ctx.epic.id)) ==
               "Waiting on you: ##{ctx.sibling.id} (nobody on it)"
    end

    test "with no job on the epic both are 'nobody on it'", ctx do
      entered_long_ago(ctx.named)
      entered_long_ago(ctx.sibling)

      reasons = ctx.owner |> Work.waiting_on_me() |> Enum.map(&{&1.card.id, &1.reason})
      assert {ctx.named.id, "needs_owner"} in reasons
      assert {ctx.sibling.id, "needs_owner"} in reasons
    end
  end
end
