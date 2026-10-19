defmodule Slipdock.PulseTest do
  @moduledoc """
  A board's pulse (#1113, `Slipdock.Pulse`): its flow numbers from the
  movement ledger and `completed_at`, and each list's usual stay with the
  fallback to its category.
  """
  use Slipdock.DataCase, async: true

  import Ecto.Query
  import Slipdock.Fixtures

  alias Slipdock.{Actor, Boards, Pulse, Repo}
  alias Slipdock.Boards.{Card, CardMove}

  @now ~U[2026-10-19 15:00:00.000000Z]

  setup do
    owner = user_fixture()
    board = board_fixture(%{"name" => "Pulse"}, owner: owner)
    [backlog, todo, doing, done] = board.columns
    %{owner: owner, board: board, backlog: backlog, todo: todo, doing: doing, done: done}
  end

  defp ago(seconds), do: DateTime.add(@now, -seconds, :second)

  # A card with no ledger rows of its own, so each test writes the history
  # it means.
  defp bare_card(column, attrs \\ %{}) do
    card = card_fixture(column, attrs)
    Repo.delete_all(from m in CardMove, where: m.card_id == ^card.id)
    card
  end

  defp row(card, kind, from, to, at) do
    Repo.insert!(%CardMove{
      card_id: card.id,
      kind: kind,
      board_id: (to || from).board_id,
      from_board_id: from && from.board_id,
      from_column_id: from && from.id,
      from_column_name: from && from.name,
      from_category: from && from.category,
      to_column_id: to && to.id,
      to_column_name: to && to.name,
      to_category: to && to.category,
      inserted_at: at
    })
  end

  defp complete(card, at, made_at \\ nil) do
    set = [completed: true, completed_at: DateTime.truncate(at, :second)]
    set = if made_at, do: [{:inserted_at, DateTime.to_naive(made_at)} | set], else: set
    Repo.update_all(from(c in Card, where: c.id == ^card.id), set: set)
  end

  # A card that came into `column` at `from_at` and left for `next` at `to_at`.
  defp stay(column, next, from_at, to_at) do
    card = bare_card(column)
    row(card, "created", nil, column, from_at)
    row(card, "moved", column, next, to_at)
    card
  end

  describe "for_board/2" do
    test "a board with no cards is zeros and nil percentiles", ctx do
      pulse = Pulse.for_board(ctx.board, now: @now)

      assert %{in_progress: 0, waiting: 0, oldest_wait_at: nil, done_7d: 0, done_today: 0} =
               pulse

      assert pulse.time_to_done == %{p50: nil, p85: nil, cards: 0, lead_time: 0}
      assert pulse.moves_24h == %{forward: 0, back: 0, total: 0}
      assert Enum.map(pulse.lists, & &1.name) == ["Backlog", "To Do", "In Progress", "Done"]
      assert Enum.all?(pulse.lists, &(&1.in_7d == 0 and &1.out_7d == 0 and &1.usual_stay == nil))
    end

    test "in progress counts open cards in doing lists; waiting counts the flag", ctx do
      card_fixture(ctx.doing)
      card_fixture(ctx.doing, %{"flags" => ["waiting"]})
      card_fixture(ctx.todo, %{"flags" => ["waiting"]})
      finished = card_fixture(ctx.doing)
      complete(finished, ago(60))
      archived = card_fixture(ctx.doing)
      {:ok, _} = Boards.archive_card(archived)

      pulse = Pulse.for_board(ctx.board, now: @now)
      assert pulse.in_progress == 2
      assert pulse.waiting == 2
    end

    test "10 cards done across 7 days: done_7d is 10 and today's are counted apart", ctx do
      for day <- 0..9, do: ctx.done |> bare_card() |> complete(ago(rem(day, 7) * 86_400 + 60))
      # Older than a week: not counted.
      ctx.done |> bare_card() |> complete(ago(8 * 86_400))

      pulse = Pulse.for_board(ctx.board, now: @now)
      assert pulse.done_7d == 10
      # Days 0 and 7 land on today (60s before 15:00).
      assert pulse.done_today == 2
    end

    test "a card ticked off where it stands counts as done", ctx do
      card = card_fixture(ctx.todo)
      {:ok, _} = Boards.toggle_completed(card)

      pulse = Pulse.for_board(ctx.board, now: DateTime.utc_now())
      assert pulse.done_7d == 1
      assert pulse.done_today == 1
    end

    test "time to done runs from the first doing entry; with none, from when it was made", ctx do
      worked = bare_card(ctx.todo)
      row(worked, "created", nil, ctx.todo, ago(10 * 3600))
      row(worked, "moved", ctx.todo, ctx.doing, ago(4 * 3600))
      # A second entry into doing doesn't restart the clock.
      row(worked, "moved", ctx.doing, ctx.todo, ago(3 * 3600))
      row(worked, "moved", ctx.todo, ctx.doing, ago(2 * 3600))
      complete(worked, @now)

      backfilled = bare_card(ctx.done)
      complete(backfilled, @now, ago(20 * 3600))

      pulse = Pulse.for_board(ctx.board, now: @now)
      assert pulse.time_to_done.cards == 2
      assert pulse.time_to_done.lead_time == 1
      # 4h and 20h: the median is between them, P85 near the top.
      assert pulse.time_to_done.p50 == 12 * 3600
      assert pulse.time_to_done.p85 == round(4 * 3600 + 0.85 * 16 * 3600)
    end

    test "moves in 24h split forward and back by list position", ctx do
      card = bare_card(ctx.todo)
      row(card, "moved", ctx.todo, ctx.doing, ago(3600))
      row(card, "moved", ctx.doing, ctx.todo, ago(1800))
      row(card, "moved", ctx.todo, ctx.done, ago(600))
      # Older than a day.
      row(card, "moved", ctx.backlog, ctx.todo, ago(2 * 86_400))

      assert Pulse.for_board(ctx.board, now: @now).moves_24h == %{forward: 2, back: 1, total: 3}
    end

    test "per-list in/out over 7 days counts arrivals from another board", ctx do
      other = board_fixture(%{"name" => "Elsewhere"}, owner: ctx.owner)
      [_, elsewhere | _] = other.columns

      card = card_fixture(elsewhere)
      {:ok, _} = Boards.move_card_to_board(card, ctx.todo, actor: Actor.web(ctx.owner))
      local = card_fixture(ctx.todo)
      :ok = Boards.move_card(local.id, ctx.doing.id, nil, actor: Actor.web(ctx.owner))

      lists = Map.new(Pulse.for_board(ctx.board).lists, &{&1.name, &1})
      # Made in To Do, plus the one in from the other board.
      assert %{in_7d: 2, out_7d: 1} = lists["To Do"]
      assert %{in_7d: 1, out_7d: 0} = lists["In Progress"]
      assert %{in_7d: 0, out_7d: 0} = lists["Done"]

      # The board it left counts it out of its list.
      left = Map.new(Pulse.for_board(other).lists, &{&1.name, &1})
      assert %{in_7d: 1, out_7d: 1} = left[elsewhere.name]
    end
  end

  describe "usual_stays/1" do
    test "a list with 8 closed stays gets its own P85", ctx do
      for h <- 1..8, do: stay(ctx.todo, ctx.doing, ago(h * 3600 + 3600), ago(3600))

      stays = Pulse.usual_stays(Boards.get_board!(ctx.board.id), now: @now)
      # Stays of 1h..8h: P85 is 85% of the way through the seven gaps.
      assert stays[ctx.todo.id] == round(3600 + 0.85 * 7 * 3600)
    end

    test "with 7, the list falls back to its category's P85", ctx do
      # 7 stays in To Do, 1 in Backlog: both todo, 8 between them.
      for h <- 1..7, do: stay(ctx.todo, ctx.doing, ago(h * 3600 + 60), ago(60))
      stay(ctx.backlog, ctx.todo, ago(8 * 3600 + 60), ago(60))

      stays = Pulse.usual_stays(ctx.board, now: @now)
      category = round(3600 + 0.85 * 7 * 3600)
      assert stays[ctx.todo.id] == category
      assert stays[ctx.backlog.id] == category
      assert stays[ctx.doing.id] == nil
    end

    test "with too few stays and no category figure, nil", ctx do
      {:ok, plain} = Boards.create_column(ctx.board, %{"name" => "Parked"})
      for h <- 1..7, do: stay(plain, ctx.doing, ago(h * 3600 + 60), ago(60))
      for h <- 1..7, do: stay(ctx.todo, ctx.doing, ago(h * 3600 + 60), ago(60))

      stays = Pulse.usual_stays(ctx.board, now: @now)
      assert stays[plain.id] == nil
      # Its category has only its own 7: still too few.
      assert stays[ctx.todo.id] == nil
    end

    test "open stays, stays that ended long ago, and gaps in the history are left out", ctx do
      for h <- 1..8, do: stay(ctx.todo, ctx.doing, ago(h * 3600 + 60), ago(60))

      # Still in To Do: no end.
      for _ <- 1..5 do
        card = bare_card(ctx.todo)
        row(card, "created", nil, ctx.todo, ago(500 * 3600))
      end

      # Ended 100 days ago: outside the 90-day window.
      stay(ctx.todo, ctx.doing, ago(101 * 86_400), ago(100 * 86_400))

      # The next row came from another list (a move the backfill dropped).
      gap = bare_card(ctx.todo)
      row(gap, "created", nil, ctx.todo, ago(400 * 3600))
      row(gap, "moved", ctx.doing, ctx.done, ago(60))

      assert Pulse.usual_stays(ctx.board, now: @now)[ctx.todo.id] ==
               round(3600 + 0.85 * 7 * 3600)
    end

    test "a loaded board carries them", ctx do
      for h <- 1..8, do: stay(ctx.todo, ctx.doing, ago(h * 3600 + 60), ago(60))
      assert Boards.get_board!(ctx.board.id).usual_stays[ctx.todo.id] > 0
    end
  end

  describe "sentence/2" do
    test "plain words, with what is missing left out" do
      pulse = %{
        in_progress: 6,
        waiting: 2,
        oldest_wait_at: ago(41 * 60),
        done_7d: 23,
        time_to_done: %{p50: 86_400}
      }

      assert Pulse.sentence(pulse, @now) ==
               "6 in progress · 2 waiting (oldest 41m) · 23 done this week · usually 1d to done"

      assert Pulse.sentence(
               %{pulse | waiting: 0, oldest_wait_at: nil, time_to_done: %{p50: nil}},
               @now
             ) == "6 in progress · 23 done this week"
    end

    test "durations read in one unit" do
      assert Enum.map([30, 120, 7200, 3 * 86_400], &Pulse.duration/1) == ["<1m", "2m", "2h", "3d"]
    end
  end
end
