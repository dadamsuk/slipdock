defmodule Slipdock.FlowTest do
  @moduledoc """
  A board's flow history (#1186, `Slipdock.Flow`): the daily series the
  Visualise page's trend charts draw, replayed from hand-written ledger rows.
  """
  use Slipdock.DataCase, async: true

  import Ecto.Query
  import Slipdock.Fixtures

  alias Slipdock.{Boards, Flow, Pulse, Repo}
  alias Slipdock.Boards.{Card, CardMove}

  # A Monday, mid-afternoon UTC.
  @now ~U[2026-10-19 15:00:00.000000Z]
  @day 86_400

  setup do
    owner = user_fixture()
    board = board_fixture(%{"name" => "Flow"}, owner: owner)
    [backlog, todo, doing, done] = board.columns
    %{owner: owner, board: board, backlog: backlog, todo: todo, doing: doing, done: done}
  end

  defp ago(seconds), do: DateTime.add(@now, -seconds, :second)

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

  defp complete(card, at) do
    Repo.update_all(from(c in Card, where: c.id == ^card.id),
      set: [completed: true, completed_at: DateTime.truncate(at, :second)]
    )
  end

  defp history(board, opts \\ []),
    do: Flow.history(board, Keyword.merge([now: @now, timezone: "Etc/UTC"], opts))

  defp on(history, %Date{} = date), do: Enum.find(history.series, &(&1.date == date))
  defp on(history, days_ago), do: on(history, Date.add(~D[2026-10-19], -days_ago))

  describe "clamp_days/1" do
    test "holds any ask to 7, 30 or 90" do
      assert Flow.clamp_days(nil) == 30
      assert Flow.clamp_days("soon") == 30
      assert Flow.clamp_days(:week) == 30
      assert Flow.clamp_days(1) == 7
      assert Flow.clamp_days("7") == 7
      assert Flow.clamp_days(8) == 30
      assert Flow.clamp_days(30) == 30
      assert Flow.clamp_days(31) == 90
      assert Flow.clamp_days(500) == 90
      assert Flow.clamp_days(-3) == 7
    end
  end

  describe "history/2" do
    test "an empty board is one zero entry per day, oldest first", ctx do
      h = history(ctx.board)

      assert h.days == 30
      assert length(h.series) == 30
      assert h.since == ~D[2026-09-20]
      assert h.until == ~D[2026-10-19]
      assert Enum.map(h.series, & &1.date) == Enum.to_list(Date.range(h.since, h.until))

      assert Enum.all?(h.series, fn d ->
               {d.backlog, d.ready, d.doing, d.done, d.completed, d.open, d.added} ==
                 {0, 0, 0, 0, 0, 0, 0}
             end)

      assert h.finished == []
      assert h.cycle == %{p50: nil, p85: nil, cards: 0}
    end

    test "days are held to the windows", ctx do
      assert length(history(ctx.board, days: 7).series) == 7
      assert length(history(ctx.board, days: 45).series) == 90
      assert history(ctx.board, days: "nonsense").days == 30
    end

    test "one card through every list lands in each band on its day", ctx do
      card = bare_card(ctx.backlog, %{"title" => "Through"})
      row(card, "created", nil, ctx.backlog, ago(5 * @day))
      row(card, "moved", ctx.backlog, ctx.todo, ago(4 * @day))
      row(card, "moved", ctx.todo, ctx.doing, ago(3 * @day))
      row(card, "moved", ctx.doing, ctx.done, ago(2 * @day))
      complete(card, ago(2 * @day))

      h = history(ctx.board, days: 7)

      assert %{backlog: 0, ready: 0, doing: 0, done: 0, open: 0, added: 0} = on(h, 6)
      assert %{backlog: 1, ready: 0, doing: 0, open: 1, added: 1} = on(h, 5)
      assert %{backlog: 0, ready: 1, doing: 0, open: 1, added: 0} = on(h, 4)
      assert %{ready: 0, doing: 1, done: 0, open: 1} = on(h, 3)
      assert %{doing: 0, done: 1, completed: 1, open: 0} = on(h, 2)
      assert %{done: 1, completed: 0} = on(h, 0)

      assert [%{id: id, title: "Through", cycle_seconds: secs}] = h.finished
      assert id == card.id
      assert secs == @day
      assert h.cycle == %{p50: @day, p85: @day, cards: 1}
    end

    test "a card moved back leaves the later band", ctx do
      card = bare_card(ctx.doing)
      row(card, "created", nil, ctx.todo, ago(4 * @day))
      row(card, "moved", ctx.todo, ctx.doing, ago(3 * @day))
      row(card, "moved", ctx.doing, ctx.todo, ago(2 * @day))

      h = history(ctx.board, days: 7)
      assert %{ready: 0, doing: 1} = on(h, 3)
      assert %{ready: 1, doing: 0, added: 0} = on(h, 2)
    end

    test "a reopened card comes off the done band and is not new scope", ctx do
      card = bare_card(ctx.todo)
      row(card, "created", nil, ctx.doing, ago(4 * @day))
      row(card, "moved", ctx.doing, ctx.done, ago(3 * @day))
      row(card, "moved", ctx.done, ctx.todo, ago(1 * @day))

      h = history(ctx.board, days: 7)
      assert %{done: 1, ready: 0, open: 0} = on(h, 3)
      assert %{done: 0, ready: 1, open: 1, added: 0} = on(h, 1)
      # Not completed now, so not finished.
      assert h.finished == []
    end

    test "done counts from the window's start, not everything ever finished", ctx do
      old = bare_card(ctx.done)
      row(old, "created", nil, ctx.done, ago(60 * @day))
      complete(old, ago(60 * @day))

      h = history(ctx.board, days: 30)
      assert Enum.all?(h.series, &(&1.done == 0))
      assert h.finished == []
      assert history(ctx.board, days: 90) |> on(0) |> Map.fetch!(:done) == 1
    end

    test "a card archived mid-window leaves the board on that day", ctx do
      card = bare_card(ctx.todo)
      row(card, "created", nil, ctx.todo, ago(5 * @day))
      row(card, "archived", ctx.todo, nil, ago(2 * @day))
      row(card, "restored", nil, ctx.backlog, ago(1 * @day))

      h = history(ctx.board, days: 7)
      assert %{ready: 1, open: 1} = on(h, 3)
      assert %{ready: 0, backlog: 0, open: 0} = on(h, 2)
      assert %{backlog: 1, open: 1, added: 1} = on(h, 1)
    end

    test "uncategorised lists are left out, and coming from one is new scope", ctx do
      {:ok, later} = Boards.create_column(ctx.board, %{"name" => "Maybe Later"})
      assert later.category == nil

      parked = bare_card(later)
      row(parked, "created", nil, later, ago(3 * @day))

      pulled = bare_card(later)
      row(pulled, "created", nil, later, ago(3 * @day))
      row(pulled, "moved", later, ctx.backlog, ago(1 * @day))

      h = history(ctx.board, days: 7)
      assert %{backlog: 0, ready: 0, doing: 0, open: 0, added: 0} = on(h, 3)
      assert %{backlog: 1, open: 1, added: 1} = on(h, 1)
    end

    test "a card ticked off in its list is counted done there, not open", ctx do
      card = bare_card(ctx.doing)
      row(card, "created", nil, ctx.doing, ago(3 * @day))
      complete(card, ago(1 * @day))

      h = history(ctx.board, days: 7)
      assert %{doing: 1, open: 1, completed: 0} = on(h, 2)
      assert %{doing: 1, open: 0, completed: 1} = on(h, 1)
      assert [%{cycle_seconds: secs}] = h.finished
      assert secs == 2 * @day
    end

    test "a card moved in from another board is new scope; a sub-board's cards are its own",
         ctx do
      other = board_fixture(%{"name" => "Elsewhere"}, owner: ctx.owner)
      [_, other_todo | _] = other.columns

      moved = bare_card(ctx.todo)
      row(moved, "created", nil, other_todo, ago(4 * @day))
      row(moved, "moved", other_todo, ctx.todo, ago(2 * @day))

      epic = card_fixture(ctx.backlog, %{"title" => "Epic"})
      Repo.delete_all(from m in CardMove, where: m.card_id == ^epic.id)
      {:ok, t} = Boards.find_template(nil, "Simple")
      {:ok, sub} = sub_board(epic, t)
      sub = Boards.get_board!(sub.id)
      sub_doing = hd(sub.columns)
      {:ok, sub_doing} = Boards.update_column(sub_doing, %{"category" => "doing"})
      child = bare_card(sub_doing)
      row(child, "created", nil, sub_doing, ago(2 * @day))

      h = history(ctx.board, days: 7)
      assert %{ready: 0, added: 0} = on(h, 3)
      assert %{ready: 1, backlog: 0, added: 1} = on(h, 2)

      sub_h = history(sub, days: 7)
      assert %{doing: 1, added: 1} = on(sub_h, 2)
    end

    test "stand-ins are never counted", ctx do
      real = card_fixture(ctx.todo, %{"title" => "Real"})
      stand_in = bare_card(ctx.todo)

      Repo.update_all(from(c in Card, where: c.id == ^stand_in.id),
        set: [stand_in_for_id: real.id]
      )

      # Even a stray row for it is ignored.
      row(stand_in, "created", nil, ctx.todo, ago(1 * @day))
      Repo.delete_all(from m in CardMove, where: m.card_id == ^real.id)

      h = history(ctx.board, days: 7)
      assert on(h, 0).ready == 0
    end

    test "days end at the board owner's midnight, not UTC's", ctx do
      Slipdock.Accounts.adopt_browser_timezone(ctx.owner, "America/New_York")

      card = bare_card(ctx.doing)
      # 02:00 UTC on the 19th is 22:00 on the 18th in New York.
      row(card, "created", nil, ctx.doing, ~U[2026-10-19 02:00:00.000000Z])
      complete(card, ~U[2026-10-19 03:00:00Z])

      h = Flow.history(ctx.board, days: 7, now: @now)
      assert h.timezone == "America/New_York"
      assert %{added: 1, completed: 1} = on(h, ~D[2026-10-18])
      assert %{added: 0, completed: 0} = on(h, ~D[2026-10-19])

      utc = history(ctx.board, days: 7)
      assert %{added: 0, completed: 0} = on(utc, ~D[2026-10-18])
      assert %{added: 1, completed: 1} = on(utc, ~D[2026-10-19])
    end

    test "weeks total the days by ISO week, Monday first", ctx do
      for days_ago <- [1, 2, 9, 40] do
        card = bare_card(ctx.done)
        row(card, "created", nil, ctx.done, ago(days_ago * @day))
        complete(card, ago(days_ago * @day))
      end

      h = history(ctx.board, days: 90)
      assert Enum.sum_by(h.weeks, & &1.completed) == 4
      assert Enum.all?(h.weeks, &(Date.day_of_week(&1.start) == 1))
      assert List.last(h.weeks) == %{week: "2026-W43", start: ~D[2026-10-19], completed: 0}
      assert %{week: "2026-W42", completed: 2} = Enum.at(h.weeks, -2)
      assert %{week: "2026-W41", completed: 1} = Enum.at(h.weeks, -3)
      # The first week is cut off by the window's start.
      assert hd(h.weeks).start == Date.beginning_of_week(h.since)
    end

    test "P50 and P85 agree with Pulse's over its 90 days", ctx do
      for {hours, n} <- Enum.with_index([1, 2, 5, 9, 30], 1) do
        card = bare_card(ctx.doing)
        row(card, "created", nil, ctx.doing, ago((n + hours) * 3600))
        complete(card, ago(n * 3600))
      end

      h = history(ctx.board, days: 90)
      pulse = Pulse.for_board(ctx.board, now: @now)
      assert h.cycle.cards == 5
      assert h.cycle.p50 == pulse.time_to_done.p50
      assert h.cycle.p85 == pulse.time_to_done.p85
    end
  end
end
