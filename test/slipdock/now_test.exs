defmodule Slipdock.NowTest do
  @moduledoc """
  What is happening right now on a board's tree (#2103, `Slipdock.Now`):
  each runner and the jobs it holds, the cards in progress across the tree
  with where they sit and what holds them, the jobs queued, the counts, and
  the board page's one-line sentence.
  """
  use Slipdock.DataCase, async: true

  import Ecto.Query
  import Slipdock.Fixtures

  alias Slipdock.{Actor, Boards, Now, Repo, Runners}
  alias Slipdock.Boards.{Card, CardMove}

  setup do
    owner = user_fixture()
    board = board_fixture(%{"name" => "Root"}, owner: owner)
    todo = Enum.find(board.columns, &(&1.category == "todo"))
    doing = Enum.find(board.columns, &(&1.category == "doing"))
    %{owner: owner, board: board, todo: todo, doing: doing}
  end

  defp runner(board, name, seen) do
    {:ok, runner, _token} = Runners.create_runner(board, %{"name" => name, "pool" => "dev"})
    Repo.update!(Ecto.Changeset.change(runner, last_seen_at: seen))
  end

  # Eight closed stays of `secs` in the doing list, the fewest a usual stay
  # is worked out from (`Slipdock.Pulse.min_stays/0`).
  defp usual_stay(ctx, secs) do
    done = Enum.find(ctx.board.columns, &(&1.category == "done"))

    for _ <- 1..8 do
      card = card_fixture(done, %{"title" => "Closed"})
      Repo.delete_all(from(m in CardMove, where: m.card_id == ^card.id))
      start = DateTime.add(DateTime.utc_now(), -(secs + 86_400))

      for {kind, from, to, at} <- [
            {"created", nil, ctx.doing, start},
            {"moved", ctx.doing, done, DateTime.add(start, secs)}
          ] do
        Repo.insert!(%CardMove{
          card_id: card.id,
          kind: kind,
          board_id: card.board_id,
          from_column_id: from && from.id,
          to_column_id: to.id,
          inserted_at: at
        })
      end
    end
  end

  defp entered(card, seconds_ago) do
    at = DateTime.add(DateTime.utc_now(), -seconds_ago)
    Repo.update_all(from(m in CardMove, where: m.card_id == ^card.id), set: [inserted_at: at])
  end

  # A sub-board whose second list is its doing list.
  defp sub(epic) do
    {:ok, t} = Boards.find_template(nil, "Simple")
    {:ok, sub} = sub_board(epic, t)
    sub = Boards.get_board!(sub.id)
    Repo.update!(Ecto.Changeset.change(Enum.at(sub.columns, 1), category: "doing"))
    Boards.get_board!(sub.id)
  end

  test "a quiet board: no runners, nothing in progress, nothing queued, no sentence", ctx do
    snap = Now.snapshot(ctx.board)

    assert snap.runners == [] and snap.in_progress == [] and snap.queued == []

    assert snap.counts == %{runners: 0, online: 0, working: 0, in_progress: 0, queued: 0}
    assert Now.sentence(snap) == nil
    assert Now.counts(ctx.board) == %{working: 0, in_progress: 0, queued: 0}
  end

  test "each runner with the job it holds and its step; an idle one holds none", ctx do
    busy = runner(ctx.board, "Mac Studio", DateTime.utc_now(:second))
    idle = runner(ctx.board, "Old box", DateTime.add(DateTime.utc_now(:second), -86_400))
    card = card_fixture(ctx.doing, %{"title" => "Build it"})

    job =
      working_job_fixture(card, %{
        runner_id: busy.id,
        pool: "dev",
        step: "Writing tests",
        step_at: DateTime.utc_now(:second),
        claimed_at: DateTime.add(DateTime.utc_now(:second), -300)
      })

    snap = Now.snapshot(ctx.board)
    by_name = Map.new(snap.runners, &{&1.name, &1})

    assert %{online: true, session: false, jobs: [j]} = by_name["Mac Studio"]
    assert j.id == job.id and j.card_id == card.id and j.card == "Build it"
    assert j.step == "Writing tests" and j.kind == "claude" and j.status == "running"
    assert j.since == job.claimed_at
    assert %{online: false, jobs: []} = by_name["Old box"]
    assert idle.id in Enum.map(snap.runners, & &1.id)
    assert snap.counts.working == 1 and snap.counts.online == 1 and snap.counts.runners == 2
  end

  test "cards in progress across the tree, with their board, list and parent epic", ctx do
    epic = card_fixture(ctx.doing, %{"title" => "Epic"})
    sub = sub(epic)
    sub_doing = Enum.find(sub.columns, &(&1.category == "doing"))
    child = card_fixture(sub_doing, %{"title" => "Child"})
    # Not in progress: a ready card, a completed one, an archived one.
    card_fixture(ctx.todo, %{"title" => "Ready"})
    card_fixture(ctx.doing, %{"title" => "Finished", "completed" => true})
    gone = card_fixture(ctx.doing, %{"title" => "Gone"})
    Repo.update!(Ecto.Changeset.change(gone, archived_at: DateTime.utc_now(:second)))

    # Asked from the sub-board, it answers for the whole tree.
    snap = Now.snapshot(sub)
    titles = Enum.map(snap.in_progress, & &1.title)

    assert Enum.sort(titles) == ["Child", "Epic"]
    row = Enum.find(snap.in_progress, &(&1.id == child.id))
    assert row.board_id == sub.id and row.board == sub.name and row.list == sub_doing.name
    assert row.parent == %{id: epic.id, title: "Epic", board_id: ctx.board.id}
    assert Enum.find(snap.in_progress, &(&1.id == epic.id)).parent == nil
    assert Now.counts(sub).in_progress == 2
  end

  test "an archived sub-board's cards are left out", ctx do
    epic = card_fixture(ctx.todo, %{"title" => "Epic"})
    sub = sub(epic)
    card_fixture(Enum.find(sub.columns, &(&1.category == "doing")), %{"title" => "Hidden"})
    Repo.update!(Ecto.Changeset.change(sub, archived_at: DateTime.utc_now(:second)))

    assert Now.snapshot(ctx.board).in_progress == []
    assert Now.counts(ctx.board).in_progress == 0
  end

  test "what holds each card: a wait, verification, a merge, a flag; and its loop", ctx do
    waiting = card_fixture(ctx.doing, %{"title" => "Asks"})
    {:ok, _} = Boards.open_wait(waiting, Actor.web(ctx.owner), %{"needs" => "Which?"})
    verifying = card_fixture(ctx.doing, %{"title" => "Checked"})
    Repo.update!(Ecto.Changeset.change(verifying, verify_state: "pending"))
    merging = card_fixture(ctx.doing, %{"title" => "Merging"})
    Repo.update!(Ecto.Changeset.change(merging, verify_state: "merging"))
    blocked = card_fixture(ctx.doing, %{"title" => "Blocked", "flags" => ["blocked"]})
    worked = card_fixture(ctx.doing, %{"title" => "Worked"})
    r = runner(ctx.board, "Mac Studio", DateTime.utc_now(:second))
    working_job_fixture(worked, %{runner_id: r.id, runner_name: "Mac Studio"})

    holds = Map.new(Now.snapshot(ctx.board).in_progress, &{&1.title, &1})

    assert holds["Asks"].holds == "waiting"
    assert holds["Asks"].state =~ "Waiting"
    assert holds["Checked"].holds == "verifying"
    assert holds["Merging"].holds == "merging"
    assert holds["Blocked"].holds == "blocked"
    assert holds["Worked"].holds == nil
    assert %{runner: "Mac Studio", kind: "build"} = holds["Worked"].loop
    assert holds["Worked"].state =~ "Running"
    assert Enum.all?([waiting, verifying, merging, blocked], &match?(%Card{}, &1))
  end

  test "stuck is the health monitor's flag alone; past the usual stay is over_usual, last (#2131)",
       ctx do
    usual_stay(ctx, 3600)
    flagged = card_fixture(ctx.doing, %{"title" => "Flagged", "flags" => ["stuck"]})
    slow = card_fixture(ctx.doing, %{"title" => "Slow"})
    entered(slow, 2 * 3600)
    checked = card_fixture(ctx.doing, %{"title" => "Slow and checked"})
    entered(checked, 2 * 3600)
    Repo.update!(Ecto.Changeset.change(checked, verify_state: "pending"))
    both = card_fixture(ctx.doing, %{"title" => "Slow and flagged", "flags" => ["stuck"]})
    entered(both, 2 * 3600)
    fresh = card_fixture(ctx.doing, %{"title" => "Fresh"})

    holds = Map.new(Now.snapshot(ctx.board).in_progress, &{&1.title, &1.holds})

    assert holds == %{
             "Flagged" => "stuck",
             "Slow" => "over_usual",
             "Slow and checked" => "verifying",
             "Slow and flagged" => "stuck",
             "Fresh" => nil
           }

    assert Enum.all?([flagged, slow, checked, both, fresh], &match?(%Card{}, &1))
  end

  test "queued jobs, with why each is held, and the sentence", ctx do
    card = card_fixture(ctx.todo, %{"title" => "Next"})
    queued = working_job_fixture(card, %{status: "queued", pool: "nobody"})
    doing = card_fixture(ctx.doing, %{"title" => "Now"})
    r = runner(ctx.board, "Mac Studio", DateTime.utc_now(:second))
    working_job_fixture(doing, %{runner_id: r.id})

    snap = Now.snapshot(ctx.board)

    assert [q] = snap.queued
    assert q.id == queued.id and q.card == "Next" and q.pool == "nobody"
    assert q.held =~ "No runner online"
    assert snap.counts.queued == 1

    assert Now.sentence(snap) == "1 runner working · 1 card in progress · 1 queued"
    assert Now.counts(ctx.board) == %{working: 1, in_progress: 1, queued: 1}

    assert Now.sentence(%{counts: %{working: 2, in_progress: 3, queued: 0}}) ==
             "2 runners working · 3 cards in progress"
  end
end
