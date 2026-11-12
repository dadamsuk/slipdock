defmodule Slipdock.DoingListSimpleTest do
  @moduledoc """
  The in-progress checks of runners, WIP, Right now, health, the overseer
  and automations read a doing list as the guide does
  (`Slipdock.Flow.doing_list?/1`, in a query `Slipdock.Flow.DoingList`): by
  its category, else by its name (#2629). Each is tried here on a sub-board
  made from the Simple template, whose "Doing" list has no category, as an
  epic's sub-board often is. Reading only `category == "doing"` missed every
  card in progress there (#2597 found it in `Lanes`).
  """
  use Slipdock.DataCase, async: true

  import Ecto.Query
  import Slipdock.Fixtures

  alias Slipdock.{Actor, Automations, Boards, Health, Now, Overseer, Repo, Runners}
  alias Slipdock.Automations.Rule
  alias Slipdock.Boards.{Board, Card, CardMove, Column, Wait}
  alias Slipdock.Health.{Context, Settings}
  alias Slipdock.Health.Detectors.{DeadBlocker, Deadlock, IdleFeed, OrphanInProgress}
  alias Slipdock.Overseer.Watch
  alias Slipdock.Runners.{Job, Runner}

  setup do
    owner = user_fixture()
    board = board_fixture(%{"name" => "Simple tree", "code" => unique_code()}, owner: owner)
    [_backlog, _todo, doing, _done] = board.columns

    epic = card_fixture(doing, %{"title" => "Epic"})
    {:ok, t} = Boards.Templates.find_template(nil, "Simple")
    {:ok, sub} = sub_board(epic, t)
    sub = Boards.get_board!(sub.id)
    sub_todo = Enum.find(sub.columns, &(&1.name == "To Do"))
    sub_doing = Enum.find(sub.columns, &(&1.name == "Doing"))

    # The Simple template's lists as an epic's sub-board has them.
    assert sub_doing.category in [nil, ""]
    assert sub_todo.category in [nil, ""]

    %{
      owner: owner,
      board: Boards.get_board!(board.id),
      epic: epic,
      sub: sub,
      sub_todo: sub_todo,
      sub_doing: sub_doing
    }
  end

  defp now, do: DateTime.utc_now(:second)
  defp ago(minutes), do: DateTime.add(now(), -minutes * 60)

  defp queue(card, attrs \\ %{}),
    do: Runners.queue(card, Map.merge(%{pool: "dev", kind: "claude", prompt: "go"}, attrs))

  defp runner(ctx, pool \\ "dev") do
    {:ok, runner, _} = Runners.create_runner(ctx.board, %{"name" => "box", "pool" => pool})
    Repo.update_all(from(r in Runner, where: r.id == ^runner.id), set: [last_seen_at: now()])
    Repo.get!(Runner, runner.id)
  end

  # The sub-board holds automated work at its "Doing" list's limit of 1.
  defp wip_full(ctx) do
    Repo.update_all(from(b in Board, where: b.id == ^ctx.sub.id), set: [automation_wip: true])
    Repo.update!(Ecto.Changeset.change(ctx.sub_doing, wip_limit: 1))
    card_fixture(ctx.sub_doing, %{"title" => "Taking the slot"})
  end

  # A rule saved disabled (so saving sends nothing), then switched on.
  defp feed_rule(ctx, column, pool) do
    rule =
      rule_fixture(
        ctx.sub,
        %{
          "trigger" => %{"type" => "list_top", "column" => column},
          "actions" => [%{"type" => "runner", "pool" => pool}]
        },
        %{"enabled" => false}
      )

    Repo.update_all(from(r in Rule, where: r.id == ^rule.id), set: [enabled: true])
    Repo.get!(Rule, rule.id)
  end

  defp detect(detector, board, changes \\ %{}),
    do:
      detector.detect(
        Context.new(board, now()),
        Settings.for(%{detector.key() => changes}, detector)
      )

  describe "runners" do
    test "a job that waits while anything is in progress waits on a worked card in Doing",
         ctx do
      runner = runner(ctx)
      busy = card_fixture(ctx.sub_doing, %{"title" => "Busy"})
      working = working_job_fixture(busy)

      {:ok, job} =
        queue(card_fixture(ctx.sub_todo, %{"title" => "Next"}), %{wait_while_doing: true})

      assert %Card{id: id} = Runners.waiting_on(job)
      assert id == busy.id
      assert Runners.held_reasons([job])[job.id] == "##{busy.id} is in progress"
      assert Runners.claim(runner) == nil

      # Once nothing works on the busy card, the job goes.
      Repo.update_all(from(j in Job, where: j.id == ^working.id), set: [status: "done"])
      assert Runners.waiting_on(Repo.reload!(job)) == nil
      assert %Job{id: claimed} = Runners.claim(runner)
      assert claimed == job.id
    end

    test "WIP: a full Doing holds a card from To Do; one in progress still goes", ctx do
      runner = runner(ctx)
      in_slot = wip_full(ctx)

      assert {%Column{id: column_id}, 1} = Runners.wip_full(ctx.sub.id)
      assert column_id == ctx.sub_doing.id

      {:ok, waiting} = queue(card_fixture(ctx.sub_todo, %{"title" => "Next"}))
      assert Runners.held_reason(waiting) == "WIP full: Doing 1/1"
      assert Runners.claim(runner) == nil

      {:ok, going} = queue(in_slot)
      assert Runners.held_reason(going) != "WIP full: Doing 1/1"
      assert %Job{id: id} = Runners.claim(runner)
      assert id == going.id
      assert Repo.reload!(waiting).status == "queued"
    end

    test "WIP off, or no limit: nothing is held", ctx do
      wip_full(ctx)
      Repo.update_all(from(b in Board, where: b.id == ^ctx.sub.id), set: [automation_wip: false])
      assert Runners.wip_full(ctx.sub.id) == nil
    end
  end

  describe "Right now" do
    test "a card in Doing is in progress, with or without a job", ctx do
      card = card_fixture(ctx.sub_doing, %{"title" => "By hand"})
      waiting = card_fixture(ctx.sub_todo, %{"title" => "Waiting"})

      rows = Now.snapshot(ctx.board).in_progress
      assert Enum.any?(rows, &(&1.id == card.id and &1.in_doing))
      refute Enum.any?(rows, &(&1.id == waiting.id))
    end
  end

  describe "health" do
    test "orphan_in_progress: an agent's card left in Doing is found", ctx do
      card = card_fixture(ctx.sub_todo, %{"title" => "Left behind"})
      actor = Actor.runner(ctx.owner, nil, "loop")

      :ok =
        Boards.Cards.move_card_to_index(Repo.get!(Card, card.id), ctx.sub_doing, :top,
          actor: actor
        )

      at = ago(180)
      Repo.update_all(from(c in Card, where: c.id == ^card.id), set: [updated_at: at])
      Repo.update_all(from(m in CardMove, where: m.card_id == ^card.id), set: [inserted_at: at])

      Repo.update_all(from(a in Slipdock.Boards.Activity, where: a.card_id == ^card.id),
        set: [inserted_at: at]
      )

      assert [f] = detect(OrphanInProgress, ctx.board)
      assert f.card_id == card.id
      assert f.summary =~ "is in Doing"
    end

    test "dead_blocker: a blocker in Doing is under way; one in a list no feed takes from isn't",
         ctx do
      feed_rule(ctx, "To Do", "loop")

      a = card_fixture(ctx.sub_todo, %{"title" => "Waiting"})
      b = card_fixture(ctx.sub_doing, %{"title" => "Under way"})
      Repo.insert_all("card_dependencies", [%{blocked_id: a.id, blocker_id: b.id}])
      assert detect(DeadBlocker, ctx.board) == []

      parked = Repo.insert!(%Column{board_id: ctx.sub.id, name: "Parked", position: 9})
      Repo.update_all(from(c in Card, where: c.id == ^b.id), set: [column_id: parked.id])
      assert [f] = detect(DeadBlocker, ctx.board)
      assert f.card_id == a.id
      assert f.summary =~ "which no feed takes from"
    end

    test "deadlock: a job waiting while a worked card in Doing is in progress is a cycle",
         ctx do
      a = card_fixture(ctx.sub_doing, %{"title" => "A"})
      b = card_fixture(ctx.sub_todo, %{"title" => "B"})
      rule = feed_rule(ctx, "To Do", "loop")

      job = fn card, attrs ->
        Repo.insert!(
          struct(
            %Job{
              board_id: card.board_id,
              root_board_id: ctx.board.id,
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

      parked = job.(a, rule_id: rule.id, status: "parked", attempts: 1)
      other = job.(a, status: "running", pool: "other")
      held = job.(b, rule_id: rule.id, attempts: 0, wait_while_doing: true)

      Repo.insert!(%Wait{
        card_id: a.id,
        job_id: parked.id,
        needs: "Which way?",
        closed_at: now(),
        close_reason: "answered",
        answer: "Left",
        requeue_state: "pending"
      })

      assert [f] = Deadlock.detect(Context.new(ctx.board), %{})
      assert f.summary =~ "job ##{held.id} waits while ##{a.id} is in progress"

      # Nothing works on A any more: no cycle.
      Repo.update_all(from(j in Job, where: j.id == ^other.id), set: [status: "done"])
      assert Deadlock.detect(Context.new(ctx.board), %{}) == []
    end

    test "idle_feed: a quiet feed held by a full Doing isn't idle; with WIP off it is", ctx do
      runner(ctx, "loop")
      wip_full(ctx)
      rule = feed_rule(ctx, "To Do", "loop")
      Repo.update_all(from(r in Rule, where: r.id == ^rule.id), set: [updated_at: ago(20)])
      card_fixture(ctx.sub_todo, %{"title" => "Next up"})

      assert detect(IdleFeed, ctx.board) == []

      Repo.update_all(from(b in Board, where: b.id == ^ctx.sub.id), set: [automation_wip: false])
      assert [f] = detect(IdleFeed, ctx.board)
      assert f.subject == %{"rule" => rule.id}
    end

    test "idle_feed: a quiet feed from a full Doing is idle: its top card is in progress",
         ctx do
      runner(ctx, "loop")
      wip_full(ctx)
      rule = feed_rule(ctx, "Doing", "loop")
      Repo.update_all(from(r in Rule, where: r.id == ^rule.id), set: [updated_at: ago(20)])

      assert [f] = detect(IdleFeed, ctx.board)
      assert f.subject == %{"rule" => rule.id}
    end

    test "Health.run on the tree raises no false dead blocker for Doing", ctx do
      feed_rule(ctx, "To Do", "loop")
      a = card_fixture(ctx.sub_todo, %{"title" => "Waiting"})
      b = card_fixture(ctx.sub_doing, %{"title" => "Under way"})
      Repo.insert_all("card_dependencies", [%{blocked_id: a.id, blocker_id: b.id}])

      assert {:ok, %{"found" => 0}} = Health.run(ctx.board, detectors: [DeadBlocker])
    end
  end

  describe "overseer" do
    setup ctx do
      {:ok, settings} = Overseer.put_settings(ctx.board, %{"enabled" => true})

      Repo.update_all(from(s in Slipdock.Overseer.Settings, where: s.id == ^settings.id),
        set: [next_run_at: DateTime.add(DateTime.utc_now(), 86_400)]
      )

      :ok
    end

    defp watch(ctx, check) do
      board = Repo.get!(Board, ctx.board.id)

      board
      |> Watch.run(Overseer.settings(board), DateTime.utc_now())
      |> Map.fetch!(:fired)
      |> Enum.filter(&(&1.check == check))
    end

    test "a pass counts the cards in Doing", ctx do
      before = Overseer.Pass.activity(ctx.board).cards_in_doing
      card_fixture(ctx.sub_doing)
      card_fixture(ctx.sub_todo)

      assert Overseer.Pass.activity(ctx.board).cards_in_doing == before + 1
    end

    test "slow: a card in Doing past the board's P85 fires", ctx do
      # Moves into an uncategorised list carry no to_category, only its name.
      started = fn card, at ->
        Repo.update_all(from(m in CardMove, where: m.card_id == ^card.id),
          set: [inserted_at: at, to_category: nil, to_column_name: "Doing", kind: "created"]
        )
      end

      for _ <- 1..8 do
        done = card_fixture(ctx.sub_doing)
        started.(done, ago(120))

        Repo.update_all(from(c in Card, where: c.id == ^done.id),
          set: [completed: true, completed_at: ago(60)]
        )
      end

      card = card_fixture(ctx.sub_doing, %{"title" => "Taking a while"})
      started.(card, ago(180))

      assert [fired] = watch(ctx, "slow")
      assert fired.subject == "card:#{card.id}:slow"
      assert fired.why =~ "P85 of 8"
    end

    test "no way forward: an epic in Doing with every subcard blocked fires", ctx do
      inner = card_fixture(ctx.sub_doing, %{"title" => "Inner epic"})
      {:ok, t} = Boards.Templates.find_template(nil, "Simple")
      {:ok, inner_sub} = sub_board(inner, t)
      col = hd(Boards.get_board!(inner_sub.id).columns)
      card_fixture(col, %{"flags" => ["blocked"]})

      assert [fired] = watch(ctx, "no_way_forward")
      assert fired.card_id == inner.id
    end
  end

  describe "automations" do
    test "a rule that waits while anything is in progress can be saved on the sub-board",
         ctx do
      spec = %{
        "trigger" => %{"type" => "list_top", "column" => "To Do"},
        "actions" => [%{"type" => "runner", "pool" => "dev", "wait_while_doing" => true}]
      }

      assert {:ok, _} =
               Automations.create_rule(%{
                 "name" => "Waits",
                 "spec" => spec,
                 "board_id" => ctx.sub.id
               })

      # A board with no doing list, by category or name, still refuses it.
      plain =
        board_fixture(%{"name" => "Plain", "code" => unique_code()}, owner: ctx.owner)

      Repo.update_all(from(c in Column, where: c.board_id == ^plain.id),
        set: [category: "todo"]
      )

      assert {:error, changeset} =
               Automations.create_rule(%{
                 "name" => "Waits",
                 "spec" => spec,
                 "board_id" => plain.id
               })

      assert {"wait_while_doing needs an in-progress list" <> _, _} = changeset.errors[:spec]
    end

    test "a feed from a full Doing sends its top card: it is the work, not more of it", ctx do
      in_slot = wip_full(ctx)
      rule = feed_rule(ctx, "Doing", "dev")

      assert {:ok, %Card{id: id}} = Automations.feed(rule)
      assert id == in_slot.id
    end

    test "a feed from To Do is held by a full Doing", ctx do
      wip_full(ctx)
      card_fixture(ctx.sub_todo, %{"title" => "Next"})
      rule = feed_rule(ctx, "To Do", "dev")

      assert Automations.feed(rule) == {:idle, :wip_full}
    end

    test "a feed from Doing isn't held by its own lane", ctx do
      Repo.update_all(from(b in Board, where: b.id == ^ctx.board.id),
        set: [lanes: true, lane_mode: "hold"]
      )

      worked = card_fixture(ctx.sub_doing, %{"title" => "Worked"})
      {:ok, _} = Boards.Cards.update_card(worked, %{"paths" => "lib/a.ex"})
      working_job_fixture(worked)

      top = card_fixture(ctx.sub_doing, %{"title" => "Top"})
      {:ok, _} = Boards.Cards.update_card(top, %{"paths" => "lib/a.ex"})
      Boards.Cards.move_card(top.id, ctx.sub_doing.id, 0)

      # The top card's lane overlaps the worked one's, but it is in progress
      # already: the lane holds nothing back from it.
      assert %Card{} = Slipdock.Lanes.conflict(Repo.get!(Card, top.id))
      rule = feed_rule(ctx, "Doing", "dev")
      assert {:ok, %Card{id: id}} = Automations.feed(rule)
      assert id == top.id
    end
  end
end
