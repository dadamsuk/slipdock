defmodule Slipdock.DoingListOutsideTest do
  @moduledoc """
  The in-progress checks #2629 left reading `category == "doing"` read a
  doing list as the guide does (#2676): by its category, else by its name
  (`Slipdock.Flow.doing_list?/1`, in a query `Slipdock.Flow.DoingList`).
  Each is tried on a list called "Doing" with no category, as a sub-board
  made from the Simple template has: a stuck job's requeue, Waiting on me's
  needs-an-owner, Pulse, DORA's idea to production, the verified-work bar
  gate and profile lock, the gardener's stale check, and the Visualise
  page's flow history (its LiveView is in
  `test/slipdock_web/live/visualise_doing_list_test.exs`).
  """
  use Slipdock.DataCase, async: true

  import Ecto.Query
  import Slipdock.Fixtures
  import Slipdock.GardenerHelpers

  alias Slipdock.{Actor, Boards, Deployments, Dora, Flow, Pulse, Repo, Runners, Work}
  alias Slipdock.Boards.{Board, Card, CardMove, Column}
  alias Slipdock.Gardener.Checks.StaleInProgress
  alias Slipdock.Gardener.Context
  alias Slipdock.Runners.{Job, Runner}

  setup do
    owner = user_fixture()
    board = board_fixture(%{"name" => "Simple tree", "code" => unique_code()}, owner: owner)
    [_backlog, _todo, doing, _done] = board.columns

    epic = card_fixture(doing, %{"title" => "Epic"})
    {:ok, t} = Boards.find_template(nil, "Simple")
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
      sub: sub,
      sub_todo: sub_todo,
      sub_doing: sub_doing,
      agent: Actor.runner(owner.id, nil, "bot")
    }
  end

  defp now, do: DateTime.utc_now(:second)
  defp ago(seconds), do: DateTime.add(now(), -seconds, :second)
  defp ago_usec(seconds), do: DateTime.add(DateTime.utc_now(), -seconds, :second)

  defp found(findings), do: Enum.flat_map(findings, & &1.subject["cards"])

  defp set_board(board, changes),
    do: Repo.update_all(from(b in Board, where: b.id == ^board.id), set: changes)

  describe "runners: requeue_stuck" do
    test "a job ending with its card still in Doing puts it back on To Do", ctx do
      {:ok, runner, _} = Runners.create_runner(ctx.board, %{"name" => "box", "pool" => "loop"})
      Repo.update_all(from(r in Runner, where: r.id == ^runner.id), set: [last_seen_at: now()])
      card = card_fixture(ctx.sub_todo, %{"title" => "Stuck"})

      # Saving the rule sends the top card of To Do.
      rule_fixture(ctx.sub, %{
        "trigger" => %{"type" => "list_top", "column" => "To Do"},
        "actions" => [%{"type" => "runner", "pool" => "loop", "requeue_stuck" => 1}]
      })

      runner = Repo.get!(Runner, runner.id)
      assert %Job{} = job = Runners.claim(runner)
      assert job.card_id == card.id
      :ok = Boards.move_card_to_index(Repo.get!(Card, card.id), ctx.sub_doing, :top)

      {:ok, job} = Runners.finish(runner, job.id, %{status: "failed"})

      assert Repo.reload!(job).recovery == "requeued"
      assert Repo.get!(Card, card.id).column_id == ctx.sub_todo.id
    end
  end

  describe "Waiting on me" do
    test "an unassigned card two hours into Doing needs an owner", ctx do
      card = card_fixture(ctx.sub_doing, %{"title" => "Nobody"})
      at = ago(7200)
      from(m in CardMove, where: m.card_id == ^card.id) |> Repo.update_all(set: [inserted_at: at])

      assert [item] =
               ctx.owner |> Work.waiting_on_me() |> Enum.filter(&(&1.card.id == card.id))

      assert item.reason == "needs_owner"
    end
  end

  describe "Pulse" do
    test "a card in Doing is in progress", ctx do
      card_fixture(ctx.sub_doing, %{"title" => "Busy"})
      card_fixture(ctx.sub_todo, %{"title" => "Next"})

      assert Pulse.for_board(ctx.sub).in_progress == 1
    end
  end

  describe "DORA: idea to production" do
    test "starts at the card's first entry into an uncategorised Doing", ctx do
      board = board_fixture(%{"name" => "Delivery", "code" => unique_code()}, owner: ctx.owner)
      {:ok, board} = Boards.update_board(board, %{"delivery_metrics" => true})
      [_backlog, todo, doing, _done] = board.columns

      Repo.update_all(from(c in Column, where: c.id == ^doing.id),
        set: [category: nil, name: "Doing"]
      )

      doing = Repo.get!(Column, doing.id)
      card = card_fixture(todo, %{"title" => "Idea"})
      :ok = Boards.move_card(card.id, doing.id, nil, actor: Actor.web(ctx.owner))

      Repo.update_all(
        from(m in CardMove, where: m.card_id == ^card.id and m.to_column_id == ^doing.id),
        set: [inserted_at: ago(48 * 3600)]
      )

      {:ok, _} =
        Deployments.start(board, %{
          environment: "production",
          sha: "abc1234def",
          status: "succeeded",
          started_at: ago(12 * 3600),
          finished_at: ago(12 * 3600 - 60),
          commits: [
            %{
              "sha" => "abc1234",
              "committed_at" => DateTime.to_iso8601(ago(13 * 3600)),
              "subject" => "ship ##{card.id}"
            }
          ]
        })

      {:ok, report} = Dora.for_board(board)
      assert report.idea_to_production.cards == 1
      assert report.idea_to_production.from_created == 0
      # 48h in Doing before a deploy 12h ago: some 36h (to the deploy minute).
      assert abs(report.idea_to_production.p50 - 36 * 3600) <= 60
    end
  end

  describe "verified work" do
    test "an agent can't start a card in Doing with no bar where the board asks for one",
         ctx do
      set_board(ctx.sub, bar_required: true)
      card = card_fixture(ctx.sub_todo, %{"title" => "Barless"})

      assert {:error, :unprocessable_entity, message} =
               Boards.move_card(card.id, ctx.sub_doing.id, nil, actor: ctx.agent)

      assert message =~ "bar"
      assert Repo.get!(Card, card.id).column_id == ctx.sub_todo.id
    end

    test "a card once in Doing stays started: an agent can't lower its profile", ctx do
      set_board(ctx.sub, profiles: true)
      card = card_fixture(ctx.sub_todo, %{"title" => "Been there", "profile" => "schema"})
      person = Actor.web(ctx.owner)
      :ok = Boards.move_card(card.id, ctx.sub_doing.id, nil, actor: person)
      :ok = Boards.move_card(card.id, ctx.sub_todo.id, nil, actor: person)

      # Only the ledger says it was started.
      Repo.update_all(from(c in Card, where: c.id == ^card.id),
        set: [profile_source: nil, bar_locked_at: nil, verify_state: nil]
      )

      card = Repo.get!(Card, card.id)
      assert {:error, _} = Boards.update_card(card, %{"profile" => "docs"}, actor: ctx.agent)
      assert Repo.get!(Card, card.id).profile == "schema"

      # A card that never was in progress is free.
      fresh = card_fixture(ctx.sub_todo, %{"title" => "Never", "profile" => "schema"})

      Repo.update_all(from(c in Card, where: c.id == ^fresh.id), set: [profile_source: nil])

      assert {:ok, %Card{profile: "docs"}} =
               Boards.update_card(Repo.get!(Card, fresh.id), %{"profile" => "docs"},
                 actor: ctx.agent
               )
    end
  end

  describe "the gardener" do
    test "stale_in_progress finds a card untouched in Doing", ctx do
      card = card_fixture(ctx.sub_doing, %{"title" => "Forgotten"})
      age(card, 14)

      assert card.id in found_ids(StaleInProgress, ctx.board)
    end

    test "stale_in_progress leaves a card whose list the context doesn't hold", ctx do
      card = card_fixture(ctx.sub_doing, %{"title" => "Listless"})
      age(card, 14)

      gardener = Context.new(Repo.get!(Board, ctx.board.id), DateTime.utc_now())
      settings = %{"days" => 14}
      assert card.id in found(StaleInProgress.find(gardener, settings))

      # No list to read: not a doing list, so not a finding.
      listless = %{gardener | columns: Map.delete(gardener.columns, ctx.sub_doing.id)}
      refute card.id in found(StaleInProgress.find(listless, settings))
    end
  end

  describe "the Visualise page's history" do
    test "a card in Doing is in the doing band, and its cycle starts there", ctx do
      card = card_fixture(ctx.sub_todo, %{"title" => "Through"})
      Repo.delete_all(from m in CardMove, where: m.card_id == ^card.id)

      row = fn kind, from, to, at ->
        Repo.insert!(%CardMove{
          card_id: card.id,
          kind: kind,
          board_id: ctx.sub.id,
          from_board_id: from && ctx.sub.id,
          from_column_id: from && from.id,
          from_column_name: from && from.name,
          from_category: from && from.category,
          to_column_id: to.id,
          to_column_name: to.name,
          to_category: to.category,
          inserted_at: at
        })
      end

      day = 86_400
      row.("created", nil, ctx.sub_todo, ago_usec(4 * day))
      row.("moved", ctx.sub_todo, ctx.sub_doing, ago_usec(3 * day))

      h = Flow.history(ctx.sub, days: 7, timezone: "Etc/UTC")
      three_ago = Date.add(Date.utc_today(), -3)
      assert %{doing: 1} = Enum.find(h.series, &(&1.date == three_ago))

      done = Enum.find(ctx.sub.columns, &(&1.name == "Done"))
      row.("moved", ctx.sub_doing, done, ago_usec(day))

      Repo.update_all(from(c in Card, where: c.id == ^card.id),
        set: [completed: true, completed_at: ago(day), column_id: done.id]
      )

      h = Flow.history(ctx.sub, days: 7, timezone: "Etc/UTC")
      assert [%{id: id, cycle_seconds: secs}] = h.finished
      assert id == card.id
      assert secs in (2 * day - 1)..(2 * day)
    end

    test "a ledger row with no list name or category is not a doing list", ctx do
      card = card_fixture(ctx.sub_todo, %{"title" => "Nameless"})
      Repo.delete_all(from m in CardMove, where: m.card_id == ^card.id)
      done = Enum.find(ctx.sub.columns, &(&1.name == "Done"))

      row = fn kind, to, at ->
        Repo.insert!(%CardMove{
          card_id: card.id,
          kind: kind,
          board_id: ctx.sub.id,
          to_column_id: to && to.id,
          to_column_name: to && to.name,
          to_category: to && to.category,
          inserted_at: at
        })
      end

      # Into a list since deleted, whose row kept neither name nor category,
      # a day before Doing.
      day = 86_400
      row.("created", ctx.sub_todo, ago_usec(5 * day))
      row.("moved", nil, ago_usec(4 * day))
      row.("moved", ctx.sub_doing, ago_usec(2 * day))
      row.("moved", done, ago_usec(day))

      Repo.update_all(from(c in Card, where: c.id == ^card.id),
        set: [completed: true, completed_at: ago(day), column_id: done.id]
      )

      h = Flow.history(ctx.sub, days: 7, timezone: "Etc/UTC")

      # Not in the doing band while there,
      four_ago = Date.add(Date.utc_today(), -4)
      assert %{doing: 0} = Enum.find(h.series, &(&1.date == four_ago))
      two_ago = Date.add(Date.utc_today(), -2)
      assert %{doing: 1} = Enum.find(h.series, &(&1.date == two_ago))

      # and the cycle starts at Doing, a day before done, not there.
      assert [%{id: id, cycle_seconds: secs}] = h.finished
      assert id == card.id
      assert secs in (day - 1)..day
    end
  end
end
