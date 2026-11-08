defmodule Slipdock.OverseerPassTest do
  @moduledoc """
  The overseer's model pass (#2068, `Slipdock.Overseer.Pass`): its pacing
  rule (10 minutes while cards are active, 30 when little is, the most when
  nothing is; an event brings it forward), what it may read (the watch's
  conditions, the pulse and the counts, never a card's text or a job's
  log), the runner job it is queued as, and the digest it leaves on the
  overseer's card.
  """
  use Slipdock.DataCase, async: true

  import Ecto.Query
  import Slipdock.Fixtures

  alias Slipdock.{Actor, Boards, Overseer, Repo, Runners}
  alias Slipdock.Boards.{Board, Card, StatusUpdate}
  alias Slipdock.Overseer.{Pacing, Pass, Settings}
  alias Slipdock.Runners.Job

  @bounds %{min_minutes: 10, max_minutes: 120}

  describe "the pacing rule" do
    test "anything in flight is active: the least minutes" do
      for key <-
            ~w(runners_busy cards_in_doing jobs_queued jobs_running waits_open conditions_open)a do
        activity = Map.put(%{ready_cards: 4}, key, 1)
        assert Pacing.level(activity) == :active
        assert Pacing.next_minutes(activity, @bounds) == 10
      end
    end

    test "nothing in flight but cards ready is little: 30, within the bounds" do
      assert Pacing.level(%{ready_cards: 2, runners_online: 3}) == :little
      assert Pacing.next_minutes(%{ready_cards: 2}, @bounds) == 30
      assert Pacing.next_minutes(%{ready_cards: 2}, %{min_minutes: 45, max_minutes: 120}) == 45
      assert Pacing.next_minutes(%{ready_cards: 2}, %{min_minutes: 5, max_minutes: 20}) == 20
    end

    test "nothing in flight and nothing ready is quiet: the most minutes" do
      assert Pacing.level(%{}) == :quiet
      assert Pacing.next_minutes(%{runners_online: 2, ready_cards: 0}, @bounds) == 120
      assert Pacing.next_minutes(%{}, %{min_minutes: 10, max_minutes: 600}) == 600
    end

    test "an event brings the next pass forward, never sooner than the gap after the last" do
      now = ~U[2026-11-08 12:00:00Z]
      next = ~U[2026-11-08 13:00:00Z]

      assert Pacing.forward(next, ~U[2026-11-08 11:00:00Z], now, false) == next
      assert Pacing.forward(next, ~U[2026-11-08 11:00:00Z], now, true) == now
      assert Pacing.forward(next, ~U[2026-11-08 11:58:00Z], now, true) == ~U[2026-11-08 12:03:00Z]
      # Never later than it was.
      assert Pacing.forward(~U[2026-11-08 12:01:00Z], ~U[2026-11-08 11:58:00Z], now, true) ==
               ~U[2026-11-08 12:01:00Z]

      assert Pacing.forward(nil, nil, now, true) == now
    end
  end

  setup do
    owner = user_fixture("overseer-pass@example.com")
    board = board_fixture(%{"name" => "Paced", "code" => unique_code()}, owner: owner)
    [_backlog, todo, doing, _done] = board.columns
    %{owner: owner, board: board, todo: todo, doing: doing}
  end

  defp on(ctx, attrs \\ %{}) do
    {:ok, settings} = Overseer.put_settings(ctx.board, Map.put(attrs, "enabled", true))
    settings
  end

  defp root(ctx), do: Repo.get!(Board, ctx.board.id)

  describe "turning it on" do
    test "makes a completed Overseer card in the done list, and the first pass due now", ctx do
      settings = on(ctx)
      card = Repo.get!(Card, settings.card_id)

      assert card.title == "Overseer"
      assert card.completed
      assert Repo.get!(Slipdock.Boards.Column, card.column_id).category == "done"
      assert DateTime.diff(DateTime.utc_now(), settings.next_run_at) < 5

      # Off and on again keeps the same card.
      {:ok, _} = Overseer.put_settings(ctx.board, %{"enabled" => false})
      assert on(ctx).card_id == card.id
    end

    test "bounds are checked: min within 5..1440 and no more than max", ctx do
      assert {:error, cs} = Overseer.put_settings(ctx.board, %{"min_minutes" => 2})
      assert errors_on(cs).min_minutes != []

      assert {:error, cs} =
               Overseer.put_settings(ctx.board, %{"min_minutes" => 60, "max_minutes" => 30})

      assert errors_on(cs).max_minutes == ["must be at least min_minutes (60)"]

      assert {:error, cs} = Overseer.put_settings(ctx.board, %{"pool" => "Not A Pool!"})
      assert errors_on(cs).pool != []
    end

    test "a sub-board's settings are its root's", ctx do
      epic = card_fixture(ctx.doing)

      {:ok, sub} =
        Boards.create_sub_board(epic, hd(Boards.list_templates(nil)), code: unique_code())

      {:ok, _} = Overseer.put_settings(Repo.get!(Board, sub.id), %{"enabled" => true})
      assert Overseer.settings(ctx.board).enabled
    end
  end

  describe "what a pass may read" do
    test "only the conditions, the pulse and the counts: no card text, comment or log", ctx do
      settings = on(ctx)

      card =
        card_fixture(ctx.doing, %{
          "title" => "Visible title",
          "description" => "SECRET-DESCRIPTION do not read"
        })

      {:ok, _} = Boards.add_comment(card, "SECRET-COMMENT", by: ctx.owner)
      working_job_fixture(card, %{status: "running", log_tail: "SECRET-LOG", step: "SECRET-STEP"})
      {:ok, _} = Boards.open_wait(card, Actor.web(ctx.owner), %{"needs" => "SECRET-WAIT"})

      Overseer.Watch.run(root(ctx), Repo.reload!(settings))
      inputs = Pass.inputs(root(ctx), Repo.reload!(settings))

      assert Map.keys(inputs) |> Enum.sort() == Enum.sort(Pass.input_keys())
      assert inputs.activity.cards_in_doing == 1
      assert inputs.activity.jobs_running == 1
      assert inputs.activity.waits_open == 1
      assert inputs.pulse.in_progress == 1
      assert inputs.next_pass_minutes == 10

      prompt = Pass.prompt(inputs)
      assert prompt =~ "Read only the JSON below"
      assert prompt =~ "never act"

      for secret <- ~w(SECRET-DESCRIPTION SECRET-COMMENT SECRET-LOG SECRET-STEP SECRET-WAIT) do
        refute prompt =~ secret, "the prompt carries #{secret}"
      end
    end

    test "the watch's conditions are in it, with why and what to do", ctx do
      settings = on(ctx)
      card = card_fixture(ctx.doing, %{"title" => "Waiting on you"})
      {:ok, _} = Boards.open_wait(card, Actor.web(ctx.owner), %{"needs" => "Which?"})
      %{fired: [condition]} = Overseer.Watch.run(root(ctx), Repo.reload!(settings))

      prompt = ctx |> root() |> Pass.inputs(Repo.reload!(settings)) |> Pass.prompt()
      assert prompt =~ ~s("check":"waiting_idle")
      assert prompt =~ ~s("id":#{condition.id})
      assert prompt =~ "Answer the waits"
    end
  end

  describe "queueing a pass" do
    test "due: an overseer job on its card, to its pool, and the next set by the pacing", ctx do
      settings = on(ctx, %{"pool" => "watch"})
      now = DateTime.utc_now(:second)

      assert {:ok, %Job{} = job} = Pass.maybe_queue(root(ctx), Repo.reload!(settings), now)
      assert job.kind == "overseer"
      assert job.pool == "watch"
      assert job.card_id == settings.card_id
      assert job.prompt =~ "overseer of the Slipdock board “Paced”"

      settings = Repo.reload!(settings)
      assert settings.last_job_id == job.id
      # Nothing in flight, nothing ready: the most minutes.
      assert DateTime.diff(settings.next_run_at, now) == 120 * 60

      # Open: not queued again, even when due.
      assert Pass.maybe_queue(root(ctx), settings, DateTime.add(now, 3 * 3600)) == :open
    end

    test "active: the next pass in min_minutes", ctx do
      settings = on(ctx)
      card_fixture(ctx.doing)
      now = DateTime.utc_now(:second)
      {:ok, _} = Pass.maybe_queue(root(ctx), Repo.reload!(settings), now)
      assert DateTime.diff(Repo.reload!(settings).next_run_at, now) == 10 * 60
    end

    test "not due: nothing queued; an event since the last pass brings it forward", ctx do
      settings = on(ctx)
      now = DateTime.utc_now(:second)
      {:ok, job} = Pass.maybe_queue(root(ctx), Repo.reload!(settings), now)

      Repo.update_all(from(j in Job, where: j.id == ^job.id),
        set: [status: "done", finished_at: now]
      )

      # The pass's own end is no event, so the next is two hours off.
      later = DateTime.add(now, 6 * 60)
      assert Pass.maybe_queue(root(ctx), Repo.reload!(settings), later) == :not_due

      card = card_fixture(ctx.todo)

      Repo.insert!(%Job{
        board_id: ctx.board.id,
        root_board_id: ctx.board.id,
        card_id: card.id,
        pool: "default",
        kind: "claude",
        prompt: "x",
        status: "done",
        finished_at: DateTime.add(now, 60)
      })

      assert {:ok, %Job{}} = Pass.maybe_queue(root(ctx), Repo.reload!(settings), later)
    end

    test "only a runner that takes overseer passes is handed one", ctx do
      settings = on(ctx)
      {:ok, job} = Pass.maybe_queue(root(ctx), Repo.reload!(settings))

      {:ok, plain, _} =
        Runners.create_runner(ctx.board, %{"name" => "plain", "pool" => "default"})

      plain = Runners.report_kinds(plain, "claude,verify")
      assert Runners.claim(plain) == nil

      {:ok, watcher, _} =
        Runners.create_runner(ctx.board, %{"name" => "watcher", "pool" => "default"})

      watcher = Runners.report_kinds(watcher, "claude,overseer")
      assert %Job{id: id} = claimed = Runners.claim(watcher)
      assert id == job.id
      assert Runners.claimed_prompt(claimed) == job.prompt
    end
  end

  describe "the digest" do
    test "a pass's JSON answer is a status update on the overseer's card", ctx do
      settings = on(ctx)
      {:ok, job} = Pass.maybe_queue(root(ctx), Repo.reload!(settings))

      {:ok, runner, _} = Runners.create_runner(ctx.board, %{"name" => "w", "pool" => "default"})
      runner = Runners.report_kinds(runner, "overseer")
      %Job{} = Runners.claim(runner)

      output =
        "Looked it over.\n" <>
          ~s({"health": "at_risk", "digest": "Overnight: 4 merged, #2040 took 3 rounds.", ) <>
          ~s("look_now": [{"condition": 7, "why": "Only you can answer it."}]})

      {:ok, _} = Runners.finish(runner, job.id, %{exit: 0, output: output})

      [update] = Repo.all(from(u in StatusUpdate, where: u.card_id == ^settings.card_id))
      assert update.health == "at_risk"
      assert update.body =~ "Overnight: 4 merged"
      assert update.body =~ "condition 7: Only you can answer it."

      settings = Repo.reload!(settings)
      assert settings.last_health == "at_risk"
      assert settings.last_digest =~ "#2040 took 3 rounds"
      # The overseer's card is done: a pass leaves no handoff on it.
      refute Boards.current_handoff(settings.card_id)
    end

    test "an answer with no digest leaves nothing" do
      assert Pass.parse("I could not decide.") == :error
      assert Pass.parse(~s({"health": "on_track"})) == :error
      assert Pass.parse(nil) == :error
      assert Pass.finished(%Job{kind: "claude"}) == :no_digest
    end

    test "the answer is found fenced, or whole; an unknown health is at risk" do
      assert {:ok, %{health: "on_track", digest: "Quiet.", look_now: []}} =
               Pass.parse("```json\n{\"health\": \"on_track\", \"digest\": \"Quiet.\"}\n```")

      assert {:ok, %{health: "at_risk"}} =
               Pass.parse(~s({"health": "fine", "digest": "Hm.", "look_now": "x"}))
    end
  end

  test "a pass queued by the tick, once due", ctx do
    on(ctx)
    Overseer.tick()

    assert [%Job{kind: "overseer"}] =
             Repo.all(from(j in Job, where: j.root_board_id == ^ctx.board.id))

    Overseer.tick()
    assert Repo.aggregate(from(j in Job, where: j.root_board_id == ^ctx.board.id), :count) == 1
    assert %Settings{} = Overseer.settings(ctx.board)
  end
end
