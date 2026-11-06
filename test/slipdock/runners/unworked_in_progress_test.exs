defmodule Slipdock.Runners.UnworkedInProgressTest do
  @moduledoc """
  #1922: a card in progress holds the board (`wait_while_doing`) and its lane
  only while a runner job is working on it — its own job queued, claimed or
  running, a verify or merge job still to finish, or its epic's job. A card
  in progress with no open job holds nothing for runners, and no held line
  names it; a pull-request board's pending card keeps its lane until its
  merge, as before; the stale and orphan in-progress checks still report it.
  """
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures
  import Slipdock.GardenerHelpers, only: [find: 2]

  alias Slipdock.{Actor, Boards, Health, Lanes, Repo, Runners}
  alias Slipdock.Boards.{Activity, Card, CardMove, Comment}
  alias Slipdock.Gardener.Checks.StaleInProgress
  alias Slipdock.Health.Detectors.OrphanInProgress
  alias Slipdock.Runners.Job

  setup do
    owner = user_fixture()
    board = board_fixture(%{"name" => "Unworked", "code" => unique_code()}, owner: owner)
    [_backlog, todo, doing, done] = board.columns
    {:ok, runner, _} = Runners.create_runner(board, %{"name" => "box", "pool" => "loop"})
    # Seen just now, so no held line falls through to "No runner online".
    runner =
      runner |> Ecto.Changeset.change(last_seen_at: DateTime.utc_now(:second)) |> Repo.update!()

    agent = %{Actor.unknown() | kind: "agent", via: "api", user_id: owner.id, agent: "bot"}

    %{
      owner: owner,
      board: board,
      todo: todo,
      doing: doing,
      done: done,
      runner: runner,
      agent: agent
    }
  end

  defp card(column, title, paths \\ []) do
    card = card_fixture(column, %{"title" => title})
    {:ok, card} = Boards.update_card(card, %{"paths" => paths})
    card
  end

  defp queue(card, attrs \\ %{}) do
    Runners.queue(
      card,
      Map.merge(%{pool: "loop", kind: "claude", prompt: "go", wait_while_doing: true}, attrs)
    )
  end

  defp lanes_on(ctx) do
    {:ok, board} = Boards.update_board(ctx.board, %{"lanes" => true})
    %{ctx | board: board}
  end

  defp claimed_id(ctx) do
    case Runners.claim(ctx.runner) do
      %Job{id: id} -> id
      nil -> nil
    end
  end

  describe "wait_while_doing" do
    test "a card in progress with no job doesn't hold the job, nor is it named", ctx do
      _idle = card(ctx.doing, "Dragged in by hand")
      {:ok, job} = queue(card(ctx.todo, "Next"))

      assert Runners.waiting_on(job) == nil
      assert Runners.held_reason(job, claimant: true) == nil
      assert Runners.held_reasons([job]) == %{}
      assert Runners.held(ctx.board, "loop") == nil
      assert claimed_id(ctx) == job.id
    end

    test "each open status of a job on the card holds it; finished ones don't", ctx do
      busy = card(ctx.doing, "Busy")
      {:ok, job} = queue(card(ctx.todo, "Next"))
      line = "##{busy.id} is in progress"

      for status <- ~w(queued claimed running) do
        other = working_job_fixture(busy, %{status: status, pool: "elsewhere"})
        assert Runners.waiting_on(job).id == busy.id, status
        assert Runners.held_reason(job, claimant: true) == line, status
        assert Runners.held_reasons([job]) == %{job.id => line}, status
        assert Runners.claim(ctx.runner) == nil, status
        Repo.delete!(other)
      end

      for status <- ~w(done failed cancelled timeout parked) do
        other = working_job_fixture(busy, %{status: status, pool: "elsewhere"})
        assert Runners.waiting_on(job) == nil, status
        assert Runners.held_reasons([job]) == %{}, status
        Repo.delete!(other)
      end

      assert claimed_id(ctx) == job.id
    end

    test "an unfinished verify or merge job on the card holds it", ctx do
      busy = card(ctx.doing, "Submitted")
      {:ok, job} = queue(card(ctx.todo, "Next"))

      for kind <- Slipdock.Verified.finishing_kinds() do
        other = working_job_fixture(busy, %{kind: kind, status: "queued", pool: "verify"})
        assert Runners.waiting_on(job).id == busy.id, kind
        assert Runners.claim(ctx.runner) == nil, kind
        Repo.delete!(other)
      end

      assert claimed_id(ctx) == job.id
    end

    test "the first card in the way that has a job is named, past one that has none", ctx do
      _idle = card(ctx.doing, "Idle")
      busy = card(ctx.doing, "Busy")
      Boards.move_card_to_index(Repo.get!(Card, busy.id), ctx.doing, :bottom)
      working_job_fixture(busy)
      {:ok, job} = queue(card(ctx.todo, "Next"))

      assert Runners.waiting_on(job).id == busy.id
      assert Runners.held_reasons([job]) == %{job.id => "##{busy.id} is in progress"}
    end

    test "a subcard in progress under an epic whose job is open counts as worked", ctx do
      {:ok, t} = Boards.find_template(nil, "Simple")
      epic = card(ctx.todo, "Epic")
      {:ok, sub} = sub_board(epic, t)
      sub = Boards.get_board!(sub.id)

      sub_doing =
        sub.columns
        |> Enum.find(&(&1.name == "Doing"))
        |> Ecto.Changeset.change(category: "doing")
        |> Repo.update!()

      child = card(sub_doing, "Child")
      assert Runners.worked(ctx.board.id) == {[], []}

      working_job_fixture(epic)
      assert {[epic_id], [sub_id]} = Runners.worked(ctx.board.id)
      assert {epic_id, sub_id} == {epic.id, sub.id}

      # A job on the sub-board waits while the child is in progress.
      {:ok, job} = queue(card(hd(sub.columns), "Sibling"))
      assert Runners.waiting_on(job).id == child.id
    end
  end

  describe "lanes" do
    setup ctx, do: lanes_on(ctx)

    test "an overlapping card in progress with no job holds no job and refuses no move", ctx do
      idle = card(ctx.doing, "Idle", "lib/**")
      next = card(ctx.todo, "Next", "lib/a.ex")
      {:ok, job} = queue(next, %{wait_while_doing: false})

      assert Lanes.conflict(next) == nil
      assert Lanes.held_cards(ctx.board.id) == %{}
      assert Runners.held_reason(job, claimant: true) == nil
      assert :ok = Boards.move_card(next.id, ctx.doing.id, nil, actor: ctx.agent)

      # Given a job, the idle card holds its lane again.
      working_job_fixture(idle, %{status: "queued", pool: "elsewhere"})
      third = card(ctx.todo, "Third", "lib/b.ex")
      assert Lanes.conflict(third).id == idle.id

      assert {:error, :unprocessable_entity, message} =
               Boards.move_card(third.id, ctx.doing.id, nil, actor: ctx.agent)

      assert message =~ "##{idle.id}"
    end

    test "a queued job is held by a worked card's lane and named; freed when the job ends",
         ctx do
      busy = card(ctx.doing, "Busy", "lib/**")
      work = working_job_fixture(busy)
      {:ok, job} = queue(card(ctx.todo, "Next", "lib/a.ex"), %{wait_while_doing: false})
      line = "Lane: overlaps ##{busy.id}, in progress"

      assert Runners.held_reason(job, claimant: true) == line
      assert Runners.held_reasons([job]) == %{job.id => line}
      assert Runners.claim(ctx.runner) == nil

      work |> Ecto.Changeset.change(status: "done") |> Repo.update!()

      assert Runners.held_reason(job, claimant: true) == nil
      assert Runners.held_reasons([job]) == %{}
      assert claimed_id(ctx) == job.id
    end

    test "a pull-request board's pending card keeps its lane with no job, until its merge",
         ctx do
      {:ok, board} =
        Boards.update_board(ctx.board, %{"verify_work" => true, "ship_via" => "pull_request"})

      ctx = %{ctx | board: board}
      pending = card(ctx.doing, "Pending", "lib/**")
      next = card(ctx.todo, "Next", "lib/a.ex")

      for state <- ["pending", "merging"] do
        Repo.update_all(from(c in Card, where: c.id == ^pending.id), set: [verify_state: state])
        assert Lanes.conflict(next).id == pending.id, state
      end

      Repo.update_all(from(c in Card, where: c.id == ^pending.id),
        set: [verify_state: "accepted"]
      )

      assert Lanes.conflict(next) == nil
    end
  end

  describe "the 2026-11-06 case" do
    test "a merged card dragged back into In Progress with no job doesn't hold the next job",
         ctx do
      {:ok, board} =
        Boards.update_board(ctx.board, %{
          "lanes" => true,
          "verify_work" => true,
          "ship_via" => "pull_request"
        })

      ctx = %{ctx | board: board}

      # #1815: built, verified and merged; its jobs all finished.
      merged = card(ctx.done, "Merged already", "lib/slipdock/**")

      Repo.update_all(from(c in Card, where: c.id == ^merged.id),
        set: [completed: true, verify_state: "accepted"]
      )

      for kind <- ["claude" | Slipdock.Verified.finishing_kinds()],
          do: working_job_fixture(merged, %{kind: kind, status: "done", pool: "loop"})

      # A stale tab drags it back into In Progress.
      :ok =
        Boards.move_card_to_index(Repo.get!(Card, merged.id), ctx.doing, :top,
          actor: Actor.web(ctx.owner)
        )

      merged = Repo.get!(Card, merged.id)
      assert merged.column_id == ctx.doing.id

      # #1878's and #1885's jobs: one overlapping its lane, one waiting while
      # anything is in progress. Neither is held, and nothing names it.
      lane = card(ctx.todo, "Overlapping", "lib/slipdock/runners.ex")
      {:ok, lane_job} = queue(lane, %{wait_while_doing: false})
      {:ok, wait_job} = queue(card(ctx.todo, "Waits while doing", "docs/x.md"))

      assert Lanes.held_cards(ctx.board.id) == %{}
      assert Runners.waiting_on(wait_job) == nil
      assert Runners.held_reasons([lane_job, wait_job]) == %{}

      assert claimed_id(ctx) == lane_job.id
      assert claimed_id(ctx) == wait_job.id
    end
  end

  describe "still reported" do
    defp age(card, days_or_minutes, unit) do
      at = DateTime.add(DateTime.utc_now(:second), -days_or_minutes, unit)
      Repo.update_all(from(c in Card, where: c.id == ^card.id), set: [updated_at: at])
      Repo.update_all(from(c in Comment, where: c.card_id == ^card.id), set: [inserted_at: at])
      Repo.update_all(from(m in CardMove, where: m.card_id == ^card.id), set: [inserted_at: at])
      Repo.update_all(from(a in Activity, where: a.card_id == ^card.id), set: [inserted_at: at])
    end

    test "a person's card in progress holding nothing is still stale to the gardener", ctx do
      idle = card(ctx.todo, "By hand")

      :ok =
        Boards.move_card_to_index(Repo.get!(Card, idle.id), ctx.doing, :top,
          actor: Actor.web(ctx.owner)
        )

      {:ok, job} = queue(card(ctx.todo, "Next"))
      assert Runners.waiting_on(job) == nil

      age(idle, 14, :day)
      assert [finding] = find(StaleInProgress, ctx.board)
      assert finding.proposal == [%{"op" => "move", "card" => idle.id, "column" => ctx.todo.id}]
    end

    test "an agent's card in progress holding nothing is still an orphan to the monitor",
         ctx do
      idle = card(ctx.todo, "Left behind")
      actor = Actor.runner(ctx.owner, nil, "loop")
      :ok = Boards.move_card_to_index(Repo.get!(Card, idle.id), ctx.doing, :top, actor: actor)

      {:ok, job} = queue(card(ctx.todo, "Next"))
      assert Runners.waiting_on(job) == nil

      age(idle, 180, :minute)
      board = Boards.get_board!(ctx.board.id)

      assert [f] =
               OrphanInProgress.detect(
                 Health.Context.new(board, DateTime.utc_now(:second)),
                 Health.Settings.for(%{}, OrphanInProgress)
               )

      assert f.card_id == idle.id
      assert f.summary =~ "with no job open on it"
    end
  end
end
