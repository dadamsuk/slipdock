defmodule Slipdock.Health.CardDetectorsTest do
  @moduledoc """
  The health monitor's detectors for cards and waits nobody is moving
  (W-2310, #1764): orphan_in_progress, unanswered_wait, dead_blocker and
  lane_hog, each against its case and its near miss.
  """
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Boards, Health, Repo}
  alias Slipdock.Automations.Rule
  alias Slipdock.Boards.{Board, Card, CardMove, Comment, Wait}
  alias Slipdock.Health.{Context, Settings}
  alias Slipdock.Health.Detectors.{DeadBlocker, LaneHog, OrphanInProgress, UnansweredWait}
  alias Slipdock.Runners.Job

  setup do
    owner = user_fixture()
    board = Boards.get_board!(board_fixture(%{"name" => "Moving"}, owner: owner).id)
    [backlog, todo, doing, done] = board.columns
    %{owner: owner, board: board, backlog: backlog, todo: todo, doing: doing, done: done}
  end

  defp now, do: DateTime.utc_now(:second)
  defp ago(minutes), do: DateTime.add(now(), -minutes * 60)

  defp detect(detector, board, changes \\ %{}) do
    detector.detect(
      Context.new(board, now()),
      Settings.for(%{detector.key() => changes}, detector)
    )
  end

  defp card!(card), do: Repo.get!(Card, card.id)

  # Everything about the card happened `minutes` ago.
  defp age(card, minutes) do
    at = ago(minutes)
    Repo.update_all(from(c in Card, where: c.id == ^card.id), set: [updated_at: at])
    Repo.update_all(from(c in Comment, where: c.card_id == ^card.id), set: [inserted_at: at])
    Repo.update_all(from(m in CardMove, where: m.card_id == ^card.id), set: [inserted_at: at])

    Repo.update_all(from(a in Slipdock.Boards.Activity, where: a.card_id == ^card.id),
      set: [inserted_at: at]
    )
  end

  defp moved_by_agent(ctx, card, column) do
    actor = Slipdock.Actor.runner(ctx.owner, nil, "loop")
    :ok = Boards.Cards.move_card_to_index(card!(card), column, :top, actor: actor)
    card!(card)
  end

  describe "orphan_in_progress" do
    test "an agent's card in progress, no job, nothing for 3 hours, is found", ctx do
      card = card_fixture(ctx.todo, %{"title" => "Left behind"})
      moved_by_agent(ctx, card, ctx.doing)
      age(card, 180)

      assert [f] = detect(OrphanInProgress, ctx.board)
      assert f.card_id == card.id
      assert f.summary =~ "is in In Progress, put there by an agent, with no job open on it"
      assert f.summary =~ "nothing done for 3 hours"
    end

    test "near misses: a person's card, an open job, recent activity, pending verification",
         ctx do
      mine = card_fixture(ctx.todo, %{"title" => "Mine"})

      :ok =
        Boards.Cards.move_card_to_index(card!(mine), ctx.doing, :top,
          actor: Slipdock.Actor.web(ctx.owner)
        )

      age(mine, 180)

      theirs = card_fixture(ctx.todo, %{"title" => "Agent's"})
      moved_by_agent(ctx, theirs, ctx.doing)
      age(theirs, 180)

      job =
        Repo.insert!(%Job{
          board_id: ctx.board.id,
          root_board_id: ctx.board.id,
          card_id: theirs.id,
          pool: "loop",
          kind: "claude",
          prompt: "",
          status: "running"
        })

      assert detect(OrphanInProgress, ctx.board) == []

      Repo.delete!(job)
      Repo.update_all(from(c in Card, where: c.id == ^theirs.id), set: [verify_state: "pending"])
      assert detect(OrphanInProgress, ctx.board) == []

      Repo.update_all(from(c in Card, where: c.id == ^theirs.id), set: [verify_state: nil])
      {:ok, _} = Boards.Comments.add_comment(card!(theirs), "Still here", by: ctx.owner)
      assert detect(OrphanInProgress, ctx.board) == []

      assert [_] =
               detect(OrphanInProgress, ctx.board, %{"minutes" => 0})
               |> Enum.filter(&(&1.card_id == theirs.id))
    end

    # #2567: an epic left in progress while a subcard waits for its verifier
    # or its merge is being worked, not orphaned (as Recovery skips it, #2371).
    defp orphaned_epic(ctx) do
      epic = card_fixture(ctx.todo, %{"title" => "Epic"})
      {:ok, t} = Boards.Templates.find_template(nil, "Simple")
      {:ok, sub} = Boards.create_sub_board(epic, t)
      sub = Boards.get_board!(sub.id)
      subcard = card_fixture(hd(sub.columns), %{"title" => "Subcard"})
      moved_by_agent(ctx, epic, ctx.doing)
      age(epic, 180)
      {epic, subcard}
    end

    defp set_subcard(subcard, set),
      do: Repo.update_all(from(c in Card, where: c.id == ^subcard.id), set: set)

    defp found?(ctx, epic),
      do: Enum.any?(detect(OrphanInProgress, ctx.board), &(&1.card_id == epic.id))

    for state <- ~w(pending merging held) do
      test "an epic whose open subcard is #{state} isn't orphaned", ctx do
        {epic, subcard} = orphaned_epic(ctx)
        assert found?(ctx, epic)

        set_subcard(subcard, verify_state: unquote(state))
        refute found?(ctx, epic)

        assert {:ok, %{"fixed" => 0}} = Health.run(ctx.board, detectors: [OrphanInProgress])
        assert card!(epic).column_id == ctx.doing.id
      end
    end

    test "an epic whose subcard isn't waiting is still found", ctx do
      {epic, subcard} = orphaned_epic(ctx)

      set_subcard(subcard, verify_state: "rejected")
      assert found?(ctx, epic)

      set_subcard(subcard, verify_state: "pending", completed: true)
      assert found?(ctx, epic)

      set_subcard(subcard, completed: false, archived_at: now())
      assert found?(ctx, epic)

      assert {:ok, %{"fixed" => 1}} = Health.run(ctx.board, detectors: [OrphanInProgress])
      assert card!(epic).column_id == ctx.todo.id
    end

    # #2915: an epic's job builds its subcards inside itself, so the one its
    # step names has no job of its own, yet is worked.
    defp epic_job_subcards(ctx) do
      epic = card_fixture(ctx.doing, %{"title" => "Epic"})
      {:ok, t} = Boards.Templates.find_template(nil, "Simple")
      {:ok, sub} = Boards.create_sub_board(epic, t)
      sub = Boards.get_board!(sub.id)
      sub_todo = Enum.find(sub.columns, &(&1.name == "To Do"))
      sub_doing = Enum.find(sub.columns, &(&1.name == "Doing"))

      [named, sibling] =
        for title <- ["Named", "Sibling"] do
          card = card_fixture(sub_todo, %{"title" => title})
          moved_by_agent(ctx, card, sub_doing)
          age(card, 180)
          card
        end

      job =
        Repo.insert!(%Job{
          board_id: ctx.board.id,
          root_board_id: ctx.board.id,
          card_id: epic.id,
          pool: "loop",
          kind: "claude",
          prompt: "",
          status: "running",
          step: "##{named.id} CI running"
        })

      %{named: named, sibling: sibling, job: job, sub_todo: sub_todo, sub_doing: sub_doing}
    end

    defp found_ids(ctx),
      do: detect(OrphanInProgress, ctx.board) |> Enum.map(& &1.card_id) |> Enum.sort()

    defp set_job(job, set), do: Repo.update_all(from(j in Job, where: j.id == ^job.id), set: set)

    for status <- ~w(claimed running) do
      test "a subcard its epic's #{status} job names isn't orphaned; its sibling is", ctx do
        %{named: named, sibling: sibling, job: job, sub_todo: sub_todo, sub_doing: sub_doing} =
          epic_job_subcards(ctx)

        set_job(job, status: unquote(status))
        assert found_ids(ctx) == [sibling.id]

        assert {:ok, %{"fixed" => 1}} = Health.run(ctx.board, detectors: [OrphanInProgress])
        assert card!(named).column_id == sub_doing.id
        assert card!(sibling).column_id == sub_todo.id
      end
    end

    test "a subcard the epic's job no longer works is orphaned again", ctx do
      %{named: named, sibling: sibling, job: job} = epic_job_subcards(ctx)
      both = Enum.sort([named.id, sibling.id])

      # The job moved on to the sibling.
      set_job(job, step: "##{sibling.id} started")
      assert found_ids(ctx) == [named.id]

      # The job ended; the epic itself, left in progress, is nobody's either.
      set_job(job, step: "##{named.id} CI running", status: "done")
      assert both -- found_ids(ctx) == []

      # A verify job on the epic builds nothing.
      set_job(job, status: "running", kind: "verify")
      assert both -- found_ids(ctx) == []

      # A running job on some other card that names it isn't its epic's.
      other = card_fixture(ctx.todo, %{"title" => "Elsewhere"})
      set_job(job, kind: "claude", card_id: other.id)
      assert both -- found_ids(ctx) == []
    end

    test "put back once with a comment, then flagged when it is orphaned again", ctx do
      card = card_fixture(ctx.todo, %{"title" => "Twice"})
      moved_by_agent(ctx, card, ctx.doing)
      age(card, 180)

      assert {:ok, %{"fixed" => 1}} = Health.run(ctx.board, detectors: [OrphanInProgress])
      assert card!(card).column_id == ctx.todo.id

      assert Repo.all(from(c in Comment, where: c.card_id == ^card.id, select: c.body))
             |> Enum.any?(&(&1 =~ "Moved back to the top of To Do"))

      # An agent takes it again and leaves it again.
      moved_by_agent(ctx, card, ctx.doing)
      age(card, 180)

      assert {:ok, %{"flagged" => 1, "fixed" => 0}} =
               Health.run(ctx.board, detectors: [OrphanInProgress])

      assert card!(card).column_id == ctx.doing.id
      assert "stuck" in card!(card).flags
    end

    test "goes back to the list its last job's feed takes from", ctx do
      rule =
        rule_fixture(
          ctx.board,
          %{
            "trigger" => %{"type" => "list_top", "column" => "Backlog"},
            "actions" => [%{"type" => "runner", "pool" => "loop"}]
          },
          %{"enabled" => false}
        )

      card = card_fixture(ctx.todo, %{"title" => "From the feed"})
      moved_by_agent(ctx, card, ctx.doing)

      Repo.insert!(%Job{
        board_id: ctx.board.id,
        root_board_id: ctx.board.id,
        card_id: card.id,
        rule_id: rule.id,
        pool: "loop",
        kind: "claude",
        prompt: "",
        status: "done"
      })

      age(card, 180)
      assert {:ok, %{"fixed" => 1}} = Health.run(ctx.board, detectors: [OrphanInProgress])
      assert card!(card).column_id == ctx.backlog.id
      assert Repo.get!(Rule, rule.id)
    end

    test "the gardener's stale_in_progress keeps people's cards and skips the agent's", ctx do
      mine = card_fixture(ctx.todo, %{"title" => "Mine"})

      :ok =
        Boards.Cards.move_card_to_index(card!(mine), ctx.doing, :top,
          actor: Slipdock.Actor.web(ctx.owner)
        )

      theirs = card_fixture(ctx.todo, %{"title" => "Agent's"})
      moved_by_agent(ctx, theirs, ctx.doing)
      age(mine, 20 * 24 * 60)
      age(theirs, 20 * 24 * 60)

      found =
        Slipdock.Gardener.Checks.StaleInProgress.find(
          Slipdock.Gardener.Context.new(ctx.board),
          %{"days" => 14}
        )

      assert Enum.map(found, & &1.subject["cards"]) == [[mine.id]]
    end
  end

  describe "unanswered_wait" do
    defp wait(ctx, card, days_ago, on \\ nil) do
      Repo.insert!(%Wait{
        card_id: card.id,
        needs: "Which colour?",
        on_user_id: on && on.id,
        opened_by_id: ctx.owner.id,
        inserted_at: ago(days_ago * 24 * 60)
      })
    end

    test "open three days is found; the fix emails the person it is on, once", ctx do
      person = user_fixture("waiting-person@example.com")
      {:ok, _} = Slipdock.Access.grant(ctx.board, person, "write", ctx.owner)
      card = card_fixture(ctx.todo, %{"title" => "Asked"})
      w = wait(ctx, card, 3, person)

      assert [f] = detect(UnansweredWait, ctx.board)
      assert f.summary =~ "question has waited 3 days for"
      assert f.summary =~ "“Which colour?”"

      assert {:ok, %{"fixed" => 1}} = Health.run(ctx.board, detectors: [UnansweredWait])

      assert_received {:email, %{subject: "Still waiting on you: “Asked”", to: [{_, to}]}}
      assert to == person.email

      # Reminded once: not again in the same period.
      assert detect(UnansweredWait, ctx.board) == []
      assert {:ok, %{"opened" => 0}} = Health.run(ctx.board, detectors: [UnansweredWait])

      # After another two days, flagged.
      Repo.update_all(from(x in Wait, where: x.id == ^w.id), set: [inserted_at: ago(5 * 24 * 60)])
      assert {:ok, %{"flagged" => 1}} = Health.run(ctx.board, detectors: [UnansweredWait])
      assert "stuck" in card!(card).flags
    end

    test "near misses: a recent wait, an answered one, a longer threshold", ctx do
      card = card_fixture(ctx.todo, %{"title" => "Asked"})
      w = wait(ctx, card, 1)
      assert detect(UnansweredWait, ctx.board) == []

      Repo.update_all(from(x in Wait, where: x.id == ^w.id), set: [inserted_at: ago(3 * 24 * 60)])
      assert detect(UnansweredWait, ctx.board, %{"days" => 4}) == []
      assert [_] = detect(UnansweredWait, ctx.board)

      Repo.update_all(from(x in Wait, where: x.id == ^w.id), set: [closed_at: now()])
      assert detect(UnansweredWait, ctx.board) == []
    end

    test "on nobody in particular, the board's owner is reminded", ctx do
      card = card_fixture(ctx.todo, %{"title" => "Anyone?"})
      wait(ctx, card, 3)
      assert {:ok, %{"fixed" => 1}} = Health.run(ctx.board, detectors: [UnansweredWait])
      owner = ctx.owner.email
      assert_received {:email, %{subject: "Still waiting on you: “Anyone?”", to: [{_, ^owner}]}}
    end
  end

  describe "dead_blocker" do
    defp block(a, b),
      do: Repo.insert_all("card_dependencies", [%{blocked_id: a.id, blocker_id: b.id}])

    test "a blocker in a dropped list is found and flagged on the blocked card", ctx do
      dropped =
        Repo.insert!(%Slipdock.Boards.Column{
          board_id: ctx.board.id,
          name: "Won't do",
          category: "dropped",
          position: 9
        })

      a = card_fixture(ctx.todo, %{"title" => "Waiting"})
      b = card_fixture(dropped, %{"title" => "Dropped"})
      block(a, b)

      assert [f] = detect(DeadBlocker, ctx.board)
      assert f.card_id == a.id
      assert f.summary =~ "is blocked by ##{b.id} “Dropped”, which is in Won't do, a dropped list"

      assert {:ok, %{"flagged" => 1}} = Health.run(ctx.board, detectors: [DeadBlocker])
      assert "stuck" in card!(a).flags
      refute "stuck" in card!(b).flags
    end

    test "with a feed, a blocker in a list no feed takes from is found; in To Do it isn't", ctx do
      rule_fixture(
        ctx.board,
        %{
          "trigger" => %{"type" => "list_top", "column" => "To Do"},
          "actions" => [%{"type" => "runner", "pool" => "loop"}]
        },
        %{"enabled" => false}
      )

      Repo.update_all(from(r in Rule, where: r.board_id == ^ctx.board.id), set: [enabled: true])

      later =
        Repo.insert!(%Slipdock.Boards.Column{
          board_id: ctx.board.id,
          name: "Maybe Later",
          category: "todo",
          position: 9
        })

      a = card_fixture(ctx.todo, %{"title" => "Waiting"})
      b = card_fixture(ctx.todo, %{"title" => "Next"})
      block(a, b)
      assert detect(DeadBlocker, ctx.board) == []

      Repo.update_all(from(c in Card, where: c.id == ^b.id), set: [column_id: later.id])
      assert [f] = detect(DeadBlocker, ctx.board)
      assert f.summary =~ "which is in Maybe Later, which no feed takes from"
    end

    test "near misses: no feed on the board, an archived or finished blocker", ctx do
      later =
        Repo.insert!(%Slipdock.Boards.Column{
          board_id: ctx.board.id,
          name: "Maybe Later",
          category: "todo",
          position: 9
        })

      a = card_fixture(ctx.todo, %{"title" => "Waiting"})
      b = card_fixture(later, %{"title" => "Someday"})
      block(a, b)
      assert detect(DeadBlocker, ctx.board) == []

      dropped =
        Repo.insert!(%Slipdock.Boards.Column{
          board_id: ctx.board.id,
          name: "Dropped",
          category: "dropped",
          position: 10
        })

      Repo.update_all(from(c in Card, where: c.id == ^b.id),
        set: [column_id: dropped.id, archived_at: now()]
      )

      assert detect(DeadBlocker, ctx.board) == []

      Repo.update_all(from(c in Card, where: c.id == ^b.id),
        set: [archived_at: nil, completed: true]
      )

      assert detect(DeadBlocker, ctx.board) == []
    end
  end

  describe "lane_hog" do
    defp lanes(ctx) do
      Repo.update_all(from(b in Board, where: b.id == ^ctx.board.id), set: [lanes: true])
      holder = card_fixture(ctx.doing, %{"title" => "Holder"})
      held = card_fixture(ctx.todo, %{"title" => "Held"})
      Repo.update_all(from(c in Card, where: c.id == ^holder.id), set: [paths: ["lib/**"]])
      Repo.update_all(from(c in Card, where: c.id == ^held.id), set: [paths: ["lib/a.ex"]])

      job =
        Repo.insert!(%Job{
          board_id: ctx.board.id,
          root_board_id: ctx.board.id,
          card_id: held.id,
          pool: "loop",
          kind: "claude",
          prompt: "",
          status: "queued",
          inserted_at: ago(5 * 60)
        })

      # Only a card a runner job is working on holds a lane (#1922).
      working_job_fixture(holder)

      {holder, held, job}
    end

    test "a lane holding a job 5 hours while nothing happens on it is found and flagged", ctx do
      {holder, held, job} = lanes(ctx)
      age(holder, 5 * 60)

      assert [f] = detect(LaneHog, ctx.board)
      assert f.card_id == holder.id

      assert f.summary =~
               "holds the lane that has kept job ##{job.id} on ##{held.id} waiting 5 hours"

      assert {:ok, %{"flagged" => 1}} = Health.run(ctx.board, detectors: [LaneHog])
      assert "stuck" in card!(holder).flags
    end

    test "near misses: the holder busy an hour ago, a job queued only 2 hours", ctx do
      {holder, _held, job} = lanes(ctx)
      age(holder, 60)
      assert detect(LaneHog, ctx.board) == []

      age(holder, 5 * 60)
      Repo.update_all(from(j in Job, where: j.id == ^job.id), set: [inserted_at: ago(120)])
      assert detect(LaneHog, ctx.board) == []
      assert [_] = detect(LaneHog, ctx.board, %{"hours" => 1})
    end
  end

  test "all four are found by the monitor" do
    keys = Enum.map(Health.detectors(), & &1.key())
    assert Enum.all?(~w(orphan_in_progress unanswered_wait dead_blocker lane_hog), &(&1 in keys))
  end
end
