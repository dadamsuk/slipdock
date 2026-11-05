defmodule Slipdock.Health.RunnerDetectorsTest do
  @moduledoc """
  The health monitor's detectors for jobs and runners (W-2310, #1761):
  no_runner, hung_job, idle_feed and long_pause, each against its case and
  its near miss, with their thresholds from the defaults and the tree's
  settings.
  """
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Boards, Health, Repo, Runners}
  alias Slipdock.Automations.{Alert, Rule}
  alias Slipdock.Health.{Context, Incident, Settings}
  alias Slipdock.Health.Detectors.{HungJob, IdleFeed, LongPause, NoRunner}
  alias Slipdock.Runners.{Job, Pause, Runner}

  setup do
    owner = user_fixture()
    board = Boards.get_board!(board_fixture(%{"name" => "Runs"}, owner: owner).id)
    [_backlog, todo, doing, _done] = board.columns
    card = card_fixture(doing, %{"title" => "Busy"})
    %{owner: owner, board: board, todo: todo, doing: doing, card: card}
  end

  defp now, do: DateTime.utc_now(:second)
  defp ago(minutes), do: DateTime.add(now(), -minutes * 60)

  defp detect(detector, board, changes \\ %{}) do
    settings = Settings.for(%{detector.key() => changes}, detector)
    detector.detect(Context.new(board, now()), settings)
  end

  defp runner(board, name, pool, seen_minutes_ago, attrs \\ []) do
    {:ok, runner, _token} = Runners.create_runner(board, %{"name" => name, "pool" => pool})
    seen = seen_minutes_ago && ago(seen_minutes_ago)

    Repo.update_all(from(r in Runner, where: r.id == ^runner.id),
      set: [last_seen_at: seen] ++ attrs
    )

    Repo.get!(Runner, runner.id)
  end

  defp job(card, attrs) do
    {:ok, job} =
      Runners.queue(card, %{pool: attrs[:pool] || "dev", kind: attrs[:kind] || "claude"})

    Repo.update_all(from(j in Job, where: j.id == ^job.id),
      set: Keyword.drop(attrs, [:pool, :kind])
    )

    Repo.get!(Job, job.id)
  end

  defp incidents(board),
    do: Repo.all(from(i in Incident, where: i.board_id == ^board.id, order_by: i.id))

  describe "no_runner" do
    test "a job queued 20 minutes with its pool's runner gone half an hour is found", ctx do
      runner(ctx.board, "box", "dev", 30)
      job = job(ctx.card, inserted_at: ago(20))

      assert [f] = detect(NoRunner, ctx.board)
      assert f.subject == %{"job" => job.id}
      assert f.card_id == ctx.card.id
      assert f.summary =~ "Job ##{job.id} (claude) has waited 20 minutes for the dev pool"
      assert f.summary =~ "no runner of that pool is online (last seen"
    end

    test "near misses: a runner seen a minute ago, gone only 10 minutes, a fresh job, a paused pool",
         ctx do
      job(ctx.card, inserted_at: ago(20))
      r = runner(ctx.board, "box", "dev", 1)
      assert detect(NoRunner, ctx.board) == []

      # Offline (past three leases) but only for 10 minutes.
      Repo.update_all(from(x in Runner, where: x.id == ^r.id), set: [last_seen_at: ago(10)])
      assert detect(NoRunner, ctx.board) == []

      Repo.update_all(from(x in Runner, where: x.id == ^r.id), set: [last_seen_at: ago(30)])
      assert [_] = detect(NoRunner, ctx.board)

      {:ok, _} = Runners.pause(ctx.board, %{"reason" => "deploy", "pool" => "dev"}, ctx.owner)
      assert detect(NoRunner, ctx.board) == []
    end

    test "a job queued only 5 minutes isn't, and a pool nobody ever connected is", ctx do
      job(ctx.card, inserted_at: ago(5))
      assert detect(NoRunner, ctx.board) == []

      other = card_fixture(ctx.todo, %{"title" => "Other"})
      job(other, inserted_at: ago(16), pool: "nobody")
      assert [f] = detect(NoRunner, ctx.board)
      assert f.summary =~ "none has ever been seen"
    end

    test "names another online pool that takes that kind of job", ctx do
      job(ctx.card, inserted_at: ago(20))
      runner(ctx.board, "spare", "loop", 0, kinds: ["claude", "merge"])
      runner(ctx.board, "verifier", "verify", 0, kinds: ["verify"])

      assert [f] = detect(NoRunner, ctx.board)
      assert f.summary =~ "Pool loop is online and takes claude jobs."
      refute f.summary =~ "verify"
    end

    test "its threshold comes from the tree's settings", ctx do
      job(ctx.card, inserted_at: ago(20))
      assert detect(NoRunner, ctx.board, %{"minutes" => 30}) == []
    end

    test "a run flags the card stuck: there is no fix", ctx do
      job(ctx.card, inserted_at: ago(20))
      assert {:ok, %{"flagged" => 1}} = Health.run(ctx.board, detectors: [NoRunner])
      assert "stuck" in Repo.get!(Boards.Card, ctx.card.id).flags
    end
  end

  describe "hung_job" do
    defp running(ctx, claimed_minutes_ago, attrs \\ []) do
      job(
        ctx.card,
        [
          status: "running",
          claimed_at: ago(claimed_minutes_ago),
          started_at: ago(claimed_minutes_ago),
          lease_expires_at: DateTime.add(now(), 60),
          runner_name: "box"
        ] ++ attrs
      )
    end

    test "a running job with a live lease and no sign of work for an hour is found", ctx do
      job = running(ctx, 60)
      assert [f] = detect(HungJob, ctx.board)
      assert f.subject == %{"job" => job.id}
      assert f.summary =~ "Job ##{job.id} (claude, box) is still holding its lease"
      assert f.summary =~ "no progress for 60 minutes"
      assert f.data == %{"job" => job.id, "cancel" => false, "kind" => "claude"}
    end

    test "near misses: a recent step, a recent note on the card, a lapsed lease", ctx do
      job = running(ctx, 60, step: "running tests", step_at: ago(5))
      assert detect(HungJob, ctx.board) == []

      Repo.update_all(from(j in Job, where: j.id == ^job.id), set: [step_at: ago(50)])
      assert [_] = detect(HungJob, ctx.board)

      {:ok, _} = Boards.add_comment(ctx.card, "Half way through", by: ctx.owner)
      assert detect(HungJob, ctx.board) == []

      Repo.update_all(from(c in Boards.Comment, where: c.card_id == ^ctx.card.id),
        set: [inserted_at: ago(50)]
      )

      Repo.update_all(from(j in Job, where: j.id == ^job.id), set: [lease_expires_at: ago(1)])
      assert detect(HungJob, ctx.board) == []
    end

    test "its threshold comes from the tree's settings", ctx do
      running(ctx, 60)
      assert detect(HungJob, ctx.board, %{"minutes" => 90}) == []
    end

    test "flagged by default; cancelled when the board allows it after cancel_minutes", ctx do
      job = running(ctx, 60)
      assert {:ok, %{"flagged" => 1}} = Health.run(ctx.board, detectors: [HungJob])
      assert Repo.get!(Job, job.id).cancel_requested_at == nil

      {:ok, _} = Settings.put(ctx.board.id, HungJob, %{"cancel" => true, "cancel_minutes" => 50})
      assert {:ok, %{"tried" => 1}} = Health.run(ctx.board, detectors: [HungJob])
      assert %DateTime{} = Repo.get!(Job, job.id).cancel_requested_at

      [_, tried] = incidents(ctx.board)
      assert List.last(tried.log)["what"] =~ "asked job ##{job.id}'s runner to stop it"

      # Asked to stop, it is no longer hung: the incident clears.
      assert {:ok, %{"cleared" => 1}} = Health.run(ctx.board, detectors: [HungJob])
    end
  end

  describe "idle_feed" do
    # A feed rule saved while disabled (so it sends nothing), then switched
    # on behind the server's back, quiet since `quiet` minutes ago.
    defp quiet_feed(ctx, quiet) do
      rule =
        rule_fixture(
          ctx.board,
          %{
            "trigger" => %{"type" => "list_top", "column" => "To Do"},
            "actions" => [%{"type" => "runner", "pool" => "loop"}]
          },
          %{"enabled" => false}
        )

      ready = card_fixture(ctx.todo, %{"title" => "Next up"})

      Repo.update_all(from(r in Rule, where: r.id == ^rule.id),
        set: [enabled: true, updated_at: ago(quiet)]
      )

      {Repo.get!(Rule, rule.id), ready}
    end

    test "a quiet feed with a ready card and an idle runner is found", ctx do
      runner(ctx.board, "box", "loop", 0)
      {rule, ready} = quiet_feed(ctx, 20)

      assert [f] = detect(IdleFeed, ctx.board)
      assert f.subject == %{"rule" => rule.id}
      assert f.card_id == nil

      assert f.summary =~
               "has sent nothing for 20 minutes, though ##{ready.id} “Next up” is ready"

      assert f.summary =~ "box is idle"
    end

    test "near misses: an empty list, a busy runner, a recent change, a paused pool", ctx do
      r = runner(ctx.board, "box", "loop", 0)
      {rule, ready} = quiet_feed(ctx, 20)

      Repo.update_all(from(x in Runner, where: x.id == ^r.id), set: [current_job_id: 1])
      assert detect(IdleFeed, ctx.board) == []
      Repo.update_all(from(x in Runner, where: x.id == ^r.id), set: [current_job_id: nil])

      Repo.update_all(from(x in Rule, where: x.id == ^rule.id), set: [updated_at: ago(5)])
      assert detect(IdleFeed, ctx.board) == []
      assert detect(IdleFeed, ctx.board, %{"minutes" => 5}) != []
      Repo.update_all(from(x in Rule, where: x.id == ^rule.id), set: [updated_at: ago(20)])

      Repo.update_all(from(c in Boards.Card, where: c.id == ^ready.id), set: [completed: true])
      assert detect(IdleFeed, ctx.board) == []
      Repo.update_all(from(c in Boards.Card, where: c.id == ^ready.id), set: [completed: false])

      {:ok, _} = Runners.pause(ctx.board, %{"reason" => "hold", "pool" => "loop"}, ctx.owner)
      assert detect(IdleFeed, ctx.board) == []
    end

    test "the fix runs the feed: the card is sent and it is fixed", ctx do
      runner(ctx.board, "box", "loop", 0)
      {rule, ready} = quiet_feed(ctx, 20)

      assert {:ok, %{"fixed" => 1, "flagged" => 0}} = Health.run(ctx.board, detectors: [IdleFeed])

      assert [%Job{card_id: card_id, status: "queued"}] =
               Repo.all(from(j in Job, where: j.rule_id == ^rule.id))

      assert card_id == ready.id
      assert [%Incident{status: "fixed", log: log}] = incidents(ctx.board)
      assert List.last(log)["what"] == "Fixed: ran the feed: it sent ##{ready.id}"
    end

    test "a feed still idle after running it is flagged, with its reason", ctx do
      runner(ctx.board, "box", "loop", 0)
      quiet_feed(ctx, 20)
      Slipdock.Config.override(:automations, enabled: false)

      assert {:ok, %{"tried" => 1, "flagged" => 0}} = Health.run(ctx.board, detectors: [IdleFeed])
      assert {:ok, %{"flagged" => 1}} = Health.run(ctx.board, detectors: [IdleFeed])

      assert [%Incident{status: "flagged", alert_id: alert_id, log: log}] = incidents(ctx.board)
      assert Enum.any?(log, &(&1["what"] =~ "ran the feed; it is still idle (disabled)"))
      assert %Alert{title: "Stuck (Feed sitting idle): Rule" <> _} = Repo.get!(Alert, alert_id)
    end
  end

  describe "long_pause" do
    defp paused(ctx, hours, pool \\ "dev") do
      {:ok, pause} =
        Runners.pause(ctx.board, %{"reason" => "bad deploy", "pool" => pool}, ctx.owner)

      Repo.update_all(from(p in Pause, where: p.id == ^pause.id),
        set: [inserted_at: ago(hours * 60)]
      )

      pause
    end

    test "a pool paused for 13 hours is found and flagged on the board", ctx do
      pause = paused(ctx, 13)
      assert [f] = detect(LongPause, ctx.board)
      assert f.subject == %{"pause" => pause.id}
      assert f.summary =~ "Pool dev has been paused for 13 hours (paused by"
      assert f.summary =~ ": bad deploy)"

      assert {:ok, %{"flagged" => 1}} = Health.run(ctx.board, detectors: [LongPause])
      assert [%Incident{alert_id: alert_id}] = incidents(ctx.board)
      assert %Alert{board_id: board_id} = Repo.get!(Alert, alert_id)
      assert board_id == ctx.board.id
    end

    test "near misses: 11 hours, a resumed pause, a longer threshold", ctx do
      paused(ctx, 11)
      assert detect(LongPause, ctx.board) == []
      assert detect(LongPause, ctx.board, %{"hours" => 10}) != []

      {:ok, _} = Runners.resume(ctx.board, "dev", ctx.owner, Slipdock.Actor.web(ctx.owner))
      assert detect(LongPause, ctx.board, %{"hours" => 10}) == []
    end
  end

  test "all four are found by the monitor, with their defaults" do
    keys = Enum.map(Health.detectors(), & &1.key())
    assert Enum.all?(~w(no_runner hung_job idle_feed long_pause), &(&1 in keys))
    assert IdleFeed.defaults()["max_attempts"] == 1
    assert HungJob.defaults() == %{"minutes" => 45, "cancel" => false, "cancel_minutes" => 120}
  end
end
