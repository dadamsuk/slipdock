defmodule Slipdock.Health.DeadlockTest do
  @moduledoc """
  The deadlock detector (W-2310, #1762): the #1750 shape rebuilt and fixed by
  withdrawing the queued job, a dependency cycle flagged on both cards with
  nothing changed, no cycle no incident, and a cycle through a claimed job
  flagged rather than fixed. Each incident names every edge in words.
  """
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Boards, Health, Repo, Runners}
  alias Slipdock.Automations.Rule
  alias Slipdock.Boards.{Board, Card, Comment, Wait}
  alias Slipdock.Health.{Context, Incident}
  alias Slipdock.Health.Detectors.Deadlock
  alias Slipdock.Runners.{Job, Runner}

  setup do
    owner = user_fixture()
    board = Boards.get_board!(board_fixture(%{"name" => "Locks"}, owner: owner).id)
    [_backlog, todo, doing, _done] = board.columns
    %{owner: owner, board: board, todo: todo, doing: doing}
  end

  defp run(board), do: Health.run(board, detectors: [Deadlock])
  defp detect(board), do: Deadlock.detect(Context.new(board), %{})
  defp card!(card), do: Repo.get!(Card, card.id)

  defp incidents(board),
    do: Repo.all(from(i in Incident, where: i.board_id == ^board.id, order_by: i.id))

  defp job(card, attrs) do
    Repo.insert!(
      struct(
        %Job{
          board_id: card.board_id,
          root_board_id: card.board_id,
          card_id: card.id,
          pool: "loop",
          kind: "claude",
          prompt: "",
          status: "queued"
        },
        attrs
      )
    )
  end

  # The #1750 shape: a list_top rule's job #373 on B is queued, held by the
  # lane of A, in progress; A's job parked on a question, whose answer is
  # held (pending) until the rule's open job — #373 — closes.
  defp shape_1750(ctx) do
    Repo.update_all(from(b in Board, where: b.id == ^ctx.board.id), set: [lanes: true])

    rule =
      rule_fixture(
        ctx.board,
        %{
          "trigger" => %{"type" => "list_top", "column" => "To Do"},
          "actions" => [%{"type" => "runner", "pool" => "loop"}]
        },
        %{"enabled" => false}
      )

    a = card_fixture(ctx.doing, %{"title" => "A"})
    b = card_fixture(ctx.todo, %{"title" => "B"})
    Repo.update_all(from(c in Card, where: c.id == ^a.id), set: [paths: ["lib/**"]])
    Repo.update_all(from(c in Card, where: c.id == ^b.id), set: [paths: ["lib/x.ex"]])
    Repo.update_all(from(r in Rule, where: r.id == ^rule.id), set: [enabled: true])

    parked = job(a, rule_id: rule.id, status: "parked", attempts: 1)
    # A parked job works nothing (#1922): A holds its lane only while some
    # other job is open on it, here one of no rule's.
    job(a, status: "running", pool: "other")
    held = job(b, rule_id: rule.id, attempts: 0)

    wait =
      Repo.insert!(%Wait{
        card_id: a.id,
        job_id: parked.id,
        needs: "Which way?",
        closed_at: DateTime.utc_now(:second),
        close_reason: "answered",
        answer: "Left",
        requeue_state: "pending"
      })

    %{rule: Repo.get!(Rule, rule.id), a: a, b: b, held: held, wait: wait}
  end

  test "the #1750 shape is found, and fixed by withdrawing the queued job; the answer goes",
       ctx do
    s = shape_1750(ctx)

    assert [f] = detect(ctx.board)
    assert f.subject["jobs"] == [s.held.id]
    assert Enum.sort(f.subject["cards"]) == Enum.sort([s.a.id, s.b.id])
    assert f.data["withdraw"] == [s.held.id]

    assert {:ok, %{"opened" => 1, "fixed" => 1, "flagged" => 0}} = run(ctx.board)

    assert %Job{status: "cancelled", recovery: "withdrawn"} = Repo.get!(Job, s.held.id)

    assert [%Job{status: "queued", card_id: card_id}] =
             Repo.all(
               from(j in Job,
                 where: j.rule_id == ^s.rule.id and j.status == "queued"
               )
             )

    assert card_id == s.a.id
    assert Repo.get!(Wait, s.wait.id).requeue_state == "queued"

    assert [%Incident{status: "fixed", log: log}] = incidents(ctx.board)
    assert List.last(log)["what"] =~ "withdrew job ##{s.held.id}, which had never been handed out"

    told =
      Repo.all(from(c in Comment, where: c.card_id == ^s.b.id, select: c.body))
      |> Enum.join("\n")

    assert told =~ "gave way to break a deadlock"
    refute "stuck" in card!(s.b).flags

    # Broken: the next run finds nothing.
    assert detect(ctx.board) == []
  end

  test "the incident names each edge in words", ctx do
    s = shape_1750(ctx)
    [f] = detect(ctx.board)

    assert f.summary =~ "A deadlock: "

    assert f.summary =~
             "job ##{s.held.id}'s card ##{s.b.id} overlaps the lane of ##{s.a.id}, in progress"

    assert f.summary =~ "##{s.a.id} waits for the answer on ##{s.a.id} to be sent"

    assert f.summary =~
             "the answer on ##{s.a.id} waits for job ##{s.held.id} (queued, on ##{s.b.id}) to close"

    assert length(f.data["edges"]) == 3
  end

  test "with only the parked job on A, A holds no lane and there is no deadlock (#1922)",
       ctx do
    s = shape_1750(ctx)

    Repo.update_all(from(j in Job, where: j.card_id == ^s.a.id and j.pool == "other"),
      set: [status: "done"]
    )

    assert Slipdock.Lanes.held_cards(ctx.board.id) == %{}
    assert Runners.held_reason(Repo.reload!(s.held), claimant: true) == nil
    assert detect(ctx.board) == []
  end

  test "a job waiting while doing is held only by a worked card, and only that is a cycle (#1922)",
       ctx do
    s = shape_1750(ctx)
    # No lanes: the queued job waits while anything is in progress instead.
    Repo.update_all(from(b in Board, where: b.id == ^ctx.board.id), set: [lanes: false])
    Repo.update_all(from(j in Job, where: j.id == ^s.held.id), set: [wait_while_doing: true])

    # A works on (its other job is running): the job waits on it, a cycle.
    assert [f] = detect(ctx.board)
    assert f.summary =~ "job ##{s.held.id} waits while ##{s.a.id} is in progress"

    # Only the parked job left on A: nothing holds the job, so no cycle.
    Repo.update_all(from(j in Job, where: j.card_id == ^s.a.id and j.pool == "other"),
      set: [status: "done"]
    )

    assert Runners.waiting_on(Repo.reload!(s.held)) == nil
    assert detect(ctx.board) == []
  end

  test "a dependency cycle is flagged on both cards, and nothing changes", ctx do
    a = card_fixture(ctx.todo, %{"title" => "Chicken"})
    b = card_fixture(ctx.todo, %{"title" => "Egg"})

    Repo.insert_all("card_dependencies", [
      %{blocked_id: a.id, blocker_id: b.id},
      %{blocked_id: b.id, blocker_id: a.id}
    ])

    assert [f] = detect(ctx.board)
    assert f.data["cards_only"]
    assert f.summary =~ "##{a.id} is blocked by ##{b.id}"
    assert f.summary =~ "##{b.id} is blocked by ##{a.id}"

    assert {:ok, %{"flagged" => 1, "fixed" => 0, "tried" => 0}} = run(ctx.board)
    assert "stuck" in card!(a).flags
    assert "stuck" in card!(b).flags
    assert card!(a).column_id == ctx.todo.id and card!(b).column_id == ctx.todo.id

    assert Repo.aggregate(
             from(d in "card_dependencies", where: d.blocked_id in ^[a.id, b.id]),
             :count
           ) == 2
  end

  test "a graph with no cycle makes no incident", ctx do
    a = card_fixture(ctx.todo, %{"title" => "First"})
    b = card_fixture(ctx.todo, %{"title" => "Second"})
    Repo.insert_all("card_dependencies", [%{blocked_id: a.id, blocker_id: b.id}])
    job(a, wait_while_doing: true)
    card_fixture(ctx.doing, %{"title" => "In the way"})

    assert detect(ctx.board) == []
    assert {:ok, %{"found" => 0}} = run(ctx.board)
  end

  # #1849, incident #2: the pass on an epic waits for its subcard to merge,
  # the subcard for its merge job, and the merge for the one runner taking
  # merges, which holds the pass.
  defp merge_shape(ctx, runner_attrs) do
    {:ok, t} = Boards.find_template(nil, "Simple")
    epic = card_fixture(ctx.doing, %{"title" => "Epic"})
    {:ok, sub} = sub_board(epic, t)
    sub = Boards.get_board!(sub.id)
    merging = card_fixture(hd(sub.columns), %{"title" => "Sub"})
    Repo.update_all(from(c in Card, where: c.id == ^merging.id), set: [verify_state: "merging"])

    {:ok, runner, _} = Runners.create_runner(ctx.board, %{"name" => "loop", "pool" => "loop"})

    pass =
      job(epic,
        status: "running",
        attempts: 1,
        runner_id: runner.id,
        claimed_at: ago(40),
        lease_expires_at: DateTime.add(DateTime.utc_now(:second), 600)
      )

    merge = job(merging, kind: "merge", board_id: sub.id, root_board_id: ctx.board.id)

    Repo.update_all(from(r in Runner, where: r.id == ^runner.id),
      set:
        [
          last_seen_at: DateTime.utc_now(:second),
          current_job_id: pass.id,
          kinds: ["claude", "merge"]
        ] ++ runner_attrs
    )

    %{epic: epic, merging: merging, runner: runner, pass: pass, merge: merge, sub: sub}
  end

  defp ago(minutes), do: DateTime.add(DateTime.utc_now(:second), -minutes * 60)

  test "a cycle through a claimed job is flagged, not fixed", ctx do
    # A runner that never said when it asked for work counts as busy.
    %{epic: epic, merging: merging, pass: pass, merge: merge} = merge_shape(ctx, [])

    assert [f] = detect(ctx.board)

    assert f.summary =~
             "job ##{pass.id} on ##{epic.id} waits for its subcard ##{merging.id} to merge"

    assert f.summary =~ "##{merging.id} waits for its merge job ##{merge.id}"
    assert f.summary =~ "merge job ##{merge.id} waits for runner loop, busy with job ##{pass.id}"
    assert f.data["withdraw"] == []

    assert {:ok, %{"flagged" => 1, "fixed" => 0}} = run(ctx.board)
    assert Repo.get!(Job, pass.id).status == "running"
    assert Repo.get!(Job, merge.id).status == "queued"
    assert "stuck" in card!(epic).flags
    assert "stuck" in card!(merging).flags
  end

  test "a runner asking for work after claiming the pass takes the merge: no deadlock", ctx do
    merge_shape(ctx, asked_at: ago(1))

    assert detect(ctx.board) == []
    assert {:ok, %{"found" => 0}} = run(ctx.board)
  end

  test "a runner that last asked before claiming the pass is busy with it", ctx do
    %{pass: pass, merge: merge} = merge_shape(ctx, asked_at: ago(41))

    assert [f] = detect(ctx.board)
    assert f.summary =~ "merge job ##{merge.id} waits for runner loop, busy with job ##{pass.id}"
  end

  test "a second claim overwriting current_job_id leaves the runner busy with both", ctx do
    %{pass: pass, merge: merge, runner: runner, sub: sub} = merge_shape(ctx, asked_at: ago(30))

    # It asked after the pass (so it takes more) and was handed a verify job,
    # which overwrote `current_job_id`; it hasn't asked since.
    other = card_fixture(hd(sub.columns), %{"title" => "Other"})

    verify =
      job(other,
        kind: "verify",
        board_id: sub.id,
        root_board_id: ctx.board.id,
        status: "running",
        runner_id: runner.id,
        claimed_at: ago(29),
        lease_expires_at: DateTime.add(DateTime.utc_now(:second), 600)
      )

    Repo.update_all(from(r in Runner, where: r.id == ^runner.id),
      set: [current_job_id: verify.id]
    )

    assert [f] = detect(ctx.board)
    assert f.summary =~ "merge job ##{merge.id} waits for runner loop, busy with job ##{pass.id}"

    # The verify job is no part of the cycle, but the merge waits on it too.
    waits = Deadlock.graph(Context.new(ctx.board))[{:job, merge.id}]

    assert {{:job, verify.id},
            "merge job ##{merge.id} waits for runner loop, busy with job ##{verify.id}"} in waits
  end

  test "one free merge runner beside a busy one: no deadlock", ctx do
    merge_shape(ctx, [])

    {:ok, free, _} = Runners.create_runner(ctx.board, %{"name" => "spare", "pool" => "loop"})

    Repo.update_all(from(r in Runner, where: r.id == ^free.id),
      set: [last_seen_at: DateTime.utc_now(:second), kinds: ["merge"]]
    )

    assert detect(ctx.board) == []
  end

  test "found by the monitor" do
    assert Deadlock in Health.detectors()
  end
end
