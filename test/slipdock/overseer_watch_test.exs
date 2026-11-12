defmodule Slipdock.OverseerWatchTest do
  @moduledoc """
  The overseer's watch checks (#2068, `Slipdock.Overseer.Watch`): each
  check fires on its condition, stays quiet without it, fires once however
  often it is seen, and clears itself when the condition ends, taking its
  alert down. A new condition is an alert on the root board and an email
  to the owner, with why and what to do.
  """
  use Slipdock.DataCase, async: true

  import Ecto.Query
  import Slipdock.Fixtures
  import Swoosh.TestAssertions

  alias Slipdock.{Actor, Boards, Overseer, Repo, Runners}
  alias Slipdock.Automations.Alert
  alias Slipdock.Boards.{Card, CardMove}
  alias Slipdock.Overseer.{Condition, Watch}
  alias Slipdock.Runners.Job

  setup do
    owner = user_fixture("overseer-owner@example.com")
    board = board_fixture(%{"name" => "Watched", "code" => unique_code()}, owner: owner)
    [_backlog, todo, doing, done] = board.columns
    {:ok, settings} = Overseer.put_settings(board, %{"enabled" => true})
    # The pass is somebody else's test: keep it from being due.
    Repo.update_all(from(s in Slipdock.Overseer.Settings, where: s.id == ^settings.id),
      set: [next_run_at: DateTime.add(DateTime.utc_now(), 86_400)]
    )

    %{owner: owner, board: board, todo: todo, doing: doing, done: done}
  end

  defp watch(ctx, now \\ DateTime.utc_now()) do
    Watch.run(Repo.get!(Slipdock.Boards.Board, ctx.board.id), Overseer.settings(ctx.board), now)
  end

  defp open(ctx, check),
    do: ctx.board.id |> Watch.open_conditions() |> Enum.filter(&(&1.check == check))

  defp job(card, attrs), do: working_job_fixture(card, attrs)

  # What one check fired or cleared in a run: others may fire beside it.
  defp fired(result, check), do: Enum.filter(result.fired, &(&1.check == check))
  defp cleared(result, check), do: Enum.filter(result.cleared, &(&1.check == check))

  describe "looping" do
    test "a card rejected twice and still under review fires, once, and clears when accepted",
         ctx do
      card = card_fixture(ctx.doing, %{"title" => "Twice round"})
      # A job open on the tree, so waiting while idle stays out of it.
      job(card, %{status: "queued", kind: "verify"})

      Repo.update_all(from(c in Card, where: c.id == ^card.id),
        set: [verify_rejections: 2, verify_state: "rejected", flags: ["review"]]
      )

      assert [fired] = fired(watch(ctx), "looping")
      assert fired.check == "looping"
      assert fired.card_id == card.id
      assert fired.title =~ "rejected 2 times"
      assert fired.todo =~ "different approach"

      alert = Repo.get!(Alert, fired.alert_id)
      assert alert.board_id == ctx.board.id
      assert alert.title =~ "Overseer: ##{card.id} is going round in circles"
      assert alert.body =~ "What to do:"
      assert_email_sent(fn email -> assert email.subject =~ "Overseer on Watched" end)

      # Seen again: no second condition, alert or email.
      assert fired(watch(ctx), "looping") == []
      assert Repo.aggregate(from(a in Alert, where: a.card_id == ^card.id), :count) == 1
      refute_email_sent()

      Repo.update_all(from(c in Card, where: c.id == ^card.id),
        set: [verify_state: "accepted", flags: []]
      )

      assert [cleared] = cleared(watch(ctx), "looping")
      assert cleared.id == fired.id
      assert open(ctx, "looping") == []
      refute Repo.get(Alert, fired.alert_id)
      assert Repo.get!(Condition, fired.id).cleared_at
    end

    test "a card circling already alerted takes that alert over, with no second email", ctx do
      card = card_fixture(ctx.doing)
      job(card, %{status: "queued", kind: "verify"})

      Repo.update_all(from(c in Card, where: c.id == ^card.id),
        set: [verify_rejections: 2, verify_state: "pending", flags: ["review"]]
      )

      {:ok, earlier} =
        Slipdock.Automations.raise_alert(%{
          "board_id" => ctx.board.id,
          "card_id" => card.id,
          "severity" => "warning",
          "title" => "Card ##{card.id} is going round in circles: 2 rejections"
        })

      assert [fired] = fired(watch(ctx), "looping")
      assert fired.alert_id == earlier.id
      refute_email_sent()
    end

    test "one rejection, or a card done, is not looping", ctx do
      once = card_fixture(ctx.doing)

      Repo.update_all(from(c in Card, where: c.id == ^once.id),
        set: [verify_rejections: 1, verify_state: "rejected", flags: ["review"]]
      )

      finished = card_fixture(ctx.done, %{"completed" => true})
      for _ <- 1..3, do: job(finished, %{status: "done"})

      assert open(ctx, "looping") == []
      assert fired(watch(ctx), "looping") == []
    end

    test "a card on its third runner pass fires; verify and cancelled jobs don't count", ctx do
      card = card_fixture(ctx.doing, %{"title" => "Third time"})
      job(card, %{status: "failed"})
      job(card, %{status: "done"})
      job(card, %{status: "done", kind: "verify"})
      job(card, %{status: "cancelled"})

      assert fired(watch(ctx), "looping") == []

      job(card, %{status: "running"})
      assert [fired] = fired(watch(ctx), "looping")
      assert fired.subject == "card:#{card.id}:passes"
      assert fired.title == "##{card.id} is on its 3rd runner pass"

      {:ok, _} = Boards.Cards.update_card(Repo.get!(Card, card.id), %{"completed" => true})
      assert [_] = cleared(watch(ctx), "looping")
    end
  end

  describe "waiting while idle" do
    test "a wait open with no job running fires, and clears when a job runs", ctx do
      card = card_fixture(ctx.doing, %{"title" => "Needs an answer"})

      {:ok, _wait} =
        Boards.Waits.open_wait(card, Actor.web(ctx.owner), %{"needs" => "Which region?"})

      assert [fired] = fired(watch(ctx), "waiting_idle")
      assert fired.check == "waiting_idle"
      assert fired.card_id == card.id
      assert fired.title =~ "Only you can move Watched on: 1 waiting, nothing running"
      assert fired.why =~ "Needs an answer"

      other = card_fixture(ctx.doing)
      job(other, %{status: "running"})
      assert [_] = cleared(watch(ctx), "waiting_idle")
    end

    test "a card flagged review with no job counts; with a job open, nothing fires", ctx do
      card = card_fixture(ctx.doing)
      Repo.update_all(from(c in Card, where: c.id == ^card.id), set: [flags: ["review"]])
      job(card, %{status: "queued", kind: "verify"})

      assert open(ctx, "waiting_idle") == []
      assert fired(watch(ctx), "waiting_idle") == []

      Repo.update_all(from(j in Job, where: j.card_id == ^card.id), set: [status: "done"])
      assert [_] = fired(watch(ctx), "waiting_idle")
    end
  end

  describe "slow" do
    defp started(card, at) do
      Repo.update_all(from(m in CardMove, where: m.card_id == ^card.id),
        set: [inserted_at: at, to_category: "doing", kind: "created"]
      )
    end

    defp history(ctx, n, seconds) do
      now = DateTime.utc_now()

      for _ <- 1..n do
        card = card_fixture(ctx.doing)
        started(card, DateTime.add(now, -seconds - 3600))

        Repo.update_all(from(c in Card, where: c.id == ^card.id),
          set: [completed: true, completed_at: DateTime.add(now, -3600, :second)]
        )
      end
    end

    test "a card in flight past the board's P85 fires, and clears when it leaves", ctx do
      history(ctx, 8, 3600)
      card = card_fixture(ctx.doing, %{"title" => "Taking a while"})
      started(card, DateTime.add(DateTime.utc_now(), -3 * 3600))

      assert [fired] = fired(watch(ctx), "slow")
      assert fired.subject == "card:#{card.id}:slow"
      assert fired.title =~ "is slow: in flight 2h 59m"
      assert fired.why =~ "P85 of 8"

      :ok = Boards.Cards.move_card(card.id, ctx.todo.id)
      assert [_] = cleared(watch(ctx), "slow")
    end

    test "under the P85, or too few done to say, is not slow", ctx do
      history(ctx, 7, 3600)
      card = card_fixture(ctx.doing)
      started(card, DateTime.add(DateTime.utc_now(), -3 * 3600))
      assert fired(watch(ctx), "slow") == []

      # Enough done now, but most took longer than this card has so far.
      history(ctx, 8, 4 * 3600)
      assert fired(watch(ctx), "slow") == []
    end

    test "a running job whose step hasn't changed in 30 min with a live lease fires", ctx do
      card = card_fixture(ctx.doing)
      now = DateTime.utc_now(:second)

      j =
        job(card, %{
          status: "running",
          step: "Running the tests",
          step_at: DateTime.add(now, -45 * 60),
          started_at: DateTime.add(now, -50 * 60),
          lease_expires_at: DateTime.add(now, 60),
          runner_name: "laptop"
        })

      assert [fired] = fired(watch(ctx), "slow")
      assert fired.subject == "job:#{j.id}:step"
      assert fired.why =~ "“Running the tests” for 45m"

      Repo.update_all(from(x in Job, where: x.id == ^j.id), set: [step_at: now])
      assert [_] = cleared(watch(ctx), "slow")
    end

    test "a job whose lease has run out, or a fresh step, is not slow", ctx do
      card = card_fixture(ctx.doing)
      now = DateTime.utc_now(:second)

      job(card, %{
        status: "running",
        step_at: DateTime.add(now, -45 * 60),
        lease_expires_at: DateTime.add(now, -10)
      })

      job(card_fixture(ctx.doing), %{
        status: "running",
        step_at: DateTime.add(now, -5 * 60),
        lease_expires_at: DateTime.add(now, 60)
      })

      assert open(ctx, "slow") == []
      assert fired(watch(ctx), "slow") == []
    end
  end

  describe "idle capacity" do
    defp runner(ctx, name, attrs) do
      {:ok, runner, _token} = Runners.create_runner(ctx.board, %{"name" => name, "pool" => "dev"})
      Repo.update_all(from(r in Slipdock.Runners.Runner, where: r.id == ^runner.id), set: attrs)
      Repo.reload!(runner)
    end

    test "free ready cards and a runner idle past idle_minutes fire; a job taken clears it",
         ctx do
      now = DateTime.utc_now(:second)
      card = card_fixture(ctx.todo, %{"title" => "Ready and waiting"})

      idle =
        runner(ctx, "idle-one",
          last_seen_at: now,
          inserted_at: DateTime.add(now, -3600)
        )

      assert [fired] = fired(watch(ctx), "idle_capacity")
      assert fired.check == "idle_capacity"
      assert fired.subject == "ready"
      assert fired.card_id == card.id
      assert fired.title == "1 ready card and 1 idle runner"
      assert fired.why =~ "idle-one"

      Repo.update_all(from(r in Slipdock.Runners.Runner, where: r.id == ^idle.id),
        set: [current_job_id: job(card, %{status: "running"}).id]
      )

      assert [_] = cleared(watch(ctx), "idle_capacity")
    end

    test "an open probe, with no card, doesn't hide the free cards (#2580)", ctx do
      now = DateTime.utc_now(:second)
      card = card_fixture(ctx.todo, %{"title" => "Ready and waiting"})
      runner(ctx, "idle-one", last_seen_at: now, inserted_at: DateTime.add(now, -3600))
      {:ok, probed, _} = Runners.create_runner(ctx.board, %{"name" => "probed", "pool" => "p"})

      Repo.insert!(%Job{
        board_id: ctx.board.id,
        root_board_id: ctx.board.id,
        for_runner_id: probed.id,
        pool: "p",
        kind: "probe",
        prompt: "",
        status: "queued"
      })

      assert [%{card_id: card_id}] = fired(watch(ctx), "idle_capacity")
      assert card_id == card.id
    end

    test "a runner offline, busy or only just idle doesn't count; nor a blocked card", ctx do
      now = DateTime.utc_now(:second)
      card_fixture(ctx.todo, %{"flags" => ["blocked"]})

      runner(ctx, "offline",
        last_seen_at: DateTime.add(now, -86_400),
        inserted_at: DateTime.add(now, -86_400)
      )

      runner(ctx, "fresh", last_seen_at: now, inserted_at: now)

      assert fired(watch(ctx), "idle_capacity") == []

      card_fixture(ctx.todo)
      # Still only a runner seen just now, idle for less than 15 minutes.
      assert fired(watch(ctx), "idle_capacity") == []
    end

    test "two jobs held behind one card's lane fire; one alone doesn't", ctx do
      {:ok, _} = Boards.update_board(ctx.board, %{"lanes" => true})
      holder = card_fixture(ctx.doing, %{"title" => "Holds docs", "paths" => ["docs/agents.md"]})
      job(holder, %{status: "running"})

      first = card_fixture(ctx.todo, %{"paths" => ["docs/agents.md"]})
      job(first, %{status: "queued"})
      assert open(ctx, "idle_capacity") == []
      assert fired(watch(ctx), "idle_capacity") == []

      second = card_fixture(ctx.todo, %{"paths" => ["docs/agents.md", "lib/x.ex"]})
      job(second, %{status: "queued"})

      assert [fired] = fired(watch(ctx), "idle_capacity")
      assert fired.subject == "lane:#{holder.id}"
      assert fired.title == "2 jobs queued behind ##{holder.id}'s lane"
      assert fired.why =~ "docs/agents.md"

      :ok = Boards.Cards.move_card(holder.id, ctx.done.id)
      assert [_] = cleared(watch(ctx), "idle_capacity")
    end
  end

  describe "no way forward" do
    defp epic(ctx) do
      epic = card_fixture(ctx.doing, %{"title" => "The epic"})

      {:ok, sub} =
        Boards.create_sub_board(epic, hd(Boards.Templates.list_templates(nil)),
          code: unique_code()
        )

      {epic, hd(Boards.get_board!(sub.id).columns)}
    end

    test "an epic in progress with every open subcard blocked fires, and clears when one frees",
         ctx do
      {epic, col} = epic(ctx)
      a = card_fixture(col, %{"flags" => ["blocked"]})
      b = card_fixture(col)
      blocker = card_fixture(ctx.todo)
      {:ok, _} = Boards.Dependencies.add_dependency(b, blocker)

      assert [fired] = fired(watch(ctx), "no_way_forward")
      assert fired.check == "no_way_forward"
      assert fired.card_id == epic.id
      assert fired.title =~ "all 2 open subcards blocked"

      {:ok, _} = Boards.Cards.update_card(Repo.get!(Card, a.id), %{"flags" => []})
      assert [_] = cleared(watch(ctx), "no_way_forward")
    end

    test "an epic with a free subcard, or not in progress, has a way forward", ctx do
      {epic, col} = epic(ctx)
      card_fixture(col, %{"flags" => ["blocked"]})
      card_fixture(col)
      assert fired(watch(ctx), "no_way_forward") == []

      :ok = Boards.Cards.move_card(epic.id, ctx.todo.id)
      sub = Repo.get_by!(Slipdock.Boards.Board, parent_card_id: epic.id)
      Repo.update_all(from(c in Card, where: c.board_id == ^sub.id), set: [flags: ["blocked"]])
      assert open(ctx, "no_way_forward") == []
      assert fired(watch(ctx), "no_way_forward") == []
    end
  end

  test "email off: the alert still goes up, no email", ctx do
    {:ok, _} = Overseer.put_settings(ctx.board, %{"email" => false})
    card = card_fixture(ctx.doing)
    {:ok, _} = Boards.Waits.open_wait(card, Actor.web(ctx.owner), %{"needs" => "Yes or no?"})

    assert [fired] = fired(watch(ctx), "waiting_idle")
    assert fired.alert_id
    refute_email_sent()
  end

  test "the tick watches only boards with the overseer on", ctx do
    other = board_fixture(%{"code" => unique_code()}, owner: ctx.owner)
    [_, _, doing, _] = other.columns
    card = card_fixture(doing)
    {:ok, _} = Boards.Waits.open_wait(card, Actor.web(ctx.owner), %{"needs" => "Anyone?"})

    Overseer.tick()

    assert Watch.open_conditions(other.id) == []
    {:ok, _} = Overseer.put_settings(other, %{"enabled" => true})
    Overseer.tick()
    assert [%{check: "waiting_idle"}] = Watch.open_conditions(other.id)
  end
end
