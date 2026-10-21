defmodule Slipdock.Flow do
  @moduledoc """
  A board's flow over time (#1186), for the Visualise page's trend charts:
  where `Slipdock.Pulse` is a snapshot with 7-day totals, this is one entry
  per day of a 7, 30 or 90 day window, replayed from the movement ledger
  (`Slipdock.Boards.CardMove`) and the cards' own `completed_at`. Worked out
  when asked for, like Pulse: nothing is stored.

  Days are the board's, which is its owner's timezone (a board has none of
  its own). Cards are counted as Pulse counts them: the board's own cards,
  never a stand-in, and a sub-board's cards on that sub-board.

  Each day in `series`, oldest first, at the end of that day (now, today):

    * `backlog`, `ready`, `doing` — cards in the board's lists of each
      kind: `ready` is the ready list (`SlipdockWeb.APIGuide.list_roles/1`),
      `backlog` every other `todo` list. Uncategorised and dropped lists are
      left out;
    * `done` — cards that came into a done list since the window began, less
      those moved back out of one into another list on the board: cumulative
      from the start of the window, so the band grows rather than starting
      at everything ever finished;
    * `completed` — cards completed that day, by `completed_at`;
    * `open` — cards in a backlog, ready or doing list not completed by then;
    * `added` — cards that came onto those lists that day from outside them:
      made, restored, or moved in from another board or a list outside the
      flow (a card reopened from done is not new scope).

  `weeks` totals `completed` by ISO week, for the 90-day view. `finished`
  has one entry per card completed in the window with its cycle seconds
  (first entry into a doing list, else when it was made, to completion:
  Pulse's rule), and `cycle` their P50 and P85.
  """

  import Ecto.Query

  alias Slipdock.Accounts.User
  alias Slipdock.Boards.{Board, Card, CardMove, Column}
  alias Slipdock.{Repo, Timezones}

  @windows [7, 30, 90]
  @default_days 30

  @doc "The windows the page offers: #{inspect(@windows)}."
  def windows, do: @windows

  @doc "The window unless asked: #{@default_days} days."
  def default_days, do: @default_days

  @doc """
  `days` held to the windows on offer: nil or nonsense is #{@default_days},
  anything else the nearest window at or above it (90 at most).
  """
  def clamp_days(nil), do: @default_days

  def clamp_days(d) when is_binary(d) do
    case Integer.parse(d) do
      {n, ""} -> clamp_days(n)
      _ -> @default_days
    end
  end

  def clamp_days(d) when is_integer(d), do: Enum.find(@windows, 90, &(d <= &1))
  def clamp_days(_), do: @default_days

  @doc "The board's timezone: its owner's."
  def timezone(%Board{owner_id: nil}), do: Timezones.default()

  def timezone(%Board{} = board) do
    owner_id = Board.root_owner_id(board)
    Timezones.of(owner_id && Repo.get(User, owner_id))
  end

  @doc """
  The ready list of `columns` (the guide's reading), or nil when it is not
  a `todo` list by category.
  """
  def ready_list(columns) do
    case SlipdockWeb.APIGuide.list_roles(columns).ready do
      %Column{category: "todo"} = col -> col
      _ -> nil
    end
  end

  @doc """
  The history of `board` over `opts[:days]` (#{inspect(@windows)}, held to
  them by `clamp_days/1`). `:now` fixes the clock and `:timezone` the day
  boundaries, for tests.
  """
  def history(%Board{id: board_id} = board, opts \\ []) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    days = opts |> Keyword.get(:days) |> clamp_days()
    tz = opts[:timezone] || timezone(board)

    today = now |> DateTime.shift_zone!(tz) |> DateTime.to_date()
    dates = Enum.to_list(Date.range(Date.add(today, -(days - 1)), today))
    ends = Enum.map(dates, &min_time(Timezones.to_utc(Date.add(&1, 1), ~T[00:00:00], tz), now))
    starts = Enum.map(dates, &Timezones.to_utc(&1, ~T[00:00:00], tz))
    window_start = hd(starts)

    columns = Repo.all(from c in Column, where: c.board_id == ^board_id)
    buckets = buckets(columns)

    completed =
      Repo.all(
        from c in Card,
          where:
            c.board_id == ^board_id and is_nil(c.stand_in_for_id) and c.completed and
              c.completed_at >= ^DateTime.truncate(window_start, :second) and
              c.completed_at <= ^DateTime.truncate(now, :second),
          select: %{id: c.id, title: c.title, completed_at: c.completed_at, made: c.inserted_at}
      )

    rows = rows(board_id, Enum.map(completed, & &1.id), now)
    cards = card_states(board_id, Map.keys(rows))

    series =
      Enum.zip([dates, starts, ends])
      |> Enum.map(fn {date, from, to} ->
        counts = positions(rows, cards, buckets, to)

        Map.merge(counts, %{
          date: date,
          done: done_since(rows, buckets, board_id, window_start, to),
          completed: Enum.count(completed, &within?(&1.completed_at, from, to)),
          added: added(rows, buckets, board_id, from, to)
        })
      end)

    finished =
      completed
      |> Enum.map(fn c ->
        started = first_doing(Map.get(rows, c.id, []), c.completed_at)
        from = started || c.made

        %{
          id: c.id,
          title: c.title,
          completed_at: c.completed_at,
          cycle_seconds: max(DateTime.diff(c.completed_at, from), 0)
        }
      end)
      |> Enum.sort_by(& &1.completed_at, DateTime)

    %{
      days: days,
      timezone: tz,
      since: hd(dates),
      until: today,
      series: series,
      weeks: weeks(series),
      finished: finished,
      cycle:
        finished
        |> Enum.map(& &1.cycle_seconds)
        |> Slipdock.Dora.percentiles()
        |> Map.put(:cards, length(finished)),
      at: DateTime.truncate(now, :second)
    }
  end

  # Which band each of the board's lists counts in; uncategorised and
  # dropped lists are in none.
  defp buckets(columns) do
    ready = ready_list(columns)

    Map.new(columns, fn col ->
      bucket =
        case col.category do
          "todo" -> if ready && ready.id == col.id, do: :ready, else: :backlog
          "doing" -> :doing
          "done" -> :done
          _ -> nil
        end

      {col.id, bucket}
    end)
  end

  # Every ledger row, oldest first, of each card that has ever been on the
  # board (and of the cards finished in the window, whose first entry into
  # a doing list may be older than their time here), keyed by card.
  defp rows(board_id, finished_ids, now) do
    ids =
      from m in CardMove,
        where: m.board_id == ^board_id or m.from_board_id == ^board_id,
        select: m.card_id

    Repo.all(
      from m in CardMove,
        where:
          (m.card_id in subquery(ids) or m.card_id in ^finished_ids) and m.inserted_at <= ^now,
        order_by: [m.card_id, m.inserted_at, m.id],
        select: %{
          card_id: m.card_id,
          kind: m.kind,
          board_id: m.board_id,
          from_board_id: m.from_board_id,
          from: m.from_column_id,
          to: m.to_column_id,
          to_category: m.to_category,
          at: m.inserted_at
        }
    )
    |> Enum.group_by(& &1.card_id)
  end

  # What is left out of the ledger: stand-ins, and when each card was completed.
  defp card_states(_board_id, []), do: %{}

  defp card_states(_board_id, ids) do
    Repo.all(
      from c in Card,
        where: c.id in ^ids,
        select: {c.id, %{stand_in: not is_nil(c.stand_in_for_id), completed_at: c.completed_at}}
    )
    |> Map.new()
  end

  # How many cards sit in each band at `at`, and how many of them are open.
  defp positions(rows, cards, buckets, at) do
    zero = %{backlog: 0, ready: 0, doing: 0, open: 0}

    Enum.reduce(rows, zero, fn {card_id, card_rows}, acc ->
      state = Map.get(cards, card_id, %{stand_in: false, completed_at: nil})

      with false <- state.stand_in,
           %{} = last <- last_before(card_rows, at),
           true <- last.kind != "archived",
           bucket when bucket in [:backlog, :ready, :doing] <- Map.get(buckets, last.to) do
        done? = state.completed_at && DateTime.compare(state.completed_at, at) != :gt

        acc
        |> Map.update!(bucket, &(&1 + 1))
        |> Map.update!(:open, &if(done?, do: &1, else: &1 + 1))
      else
        _ -> acc
      end
    end)
  end

  defp last_before(card_rows, at) do
    card_rows
    |> Enum.take_while(&(DateTime.compare(&1.at, at) != :gt))
    |> List.last()
  end

  # Into a done list from anywhere that isn't one, less back out of one into
  # another list on the board, between the window's start and `to`.
  defp done_since(rows, buckets, board_id, from, to) do
    rows
    |> Enum.flat_map(&elem(&1, 1))
    |> Enum.filter(&within?(&1.at, from, to))
    |> Enum.reduce(0, fn r, n ->
      to_done = r.board_id == board_id and buckets[r.to] == :done
      from_done = r.from_board_id == board_id and buckets[r.from] == :done

      cond do
        r.kind in CardMove.entry_kinds() and to_done and not from_done -> n + 1
        r.kind == "moved" and from_done and not to_done and r.board_id == board_id -> n - 1
        true -> n
      end
    end)
    |> max(0)
  end

  # Onto the board's backlog, ready or doing lists from outside them: made,
  # restored, or moved in from another board or a list outside the flow.
  defp added(rows, buckets, board_id, from, to) do
    rows
    |> Enum.flat_map(&elem(&1, 1))
    |> Enum.count(fn r ->
      within?(r.at, from, to) and r.board_id == board_id and
        buckets[r.to] in [:backlog, :ready, :doing] and
        (r.kind in ["created", "restored"] or
           (r.kind == "moved" and
              (r.from_board_id != board_id or
                 buckets[r.from] not in [:backlog, :ready, :doing, :done])))
    end)
  end

  defp first_doing(card_rows, completed_at) do
    Enum.find_value(card_rows, fn r ->
      if r.to_category == "doing" and r.kind in CardMove.entry_kinds() and
           DateTime.compare(r.at, completed_at) != :gt,
         do: r.at
    end)
  end

  defp weeks(series) do
    series
    |> Enum.chunk_by(&Date.beginning_of_week(&1.date))
    |> Enum.map(fn [first | _] = days ->
      {year, week} = :calendar.iso_week_number(Date.to_erl(first.date))

      %{
        week: "#{year}-W#{String.pad_leading(to_string(week), 2, "0")}",
        start: Date.beginning_of_week(first.date),
        completed: Enum.sum_by(days, & &1.completed)
      }
    end)
  end

  defp within?(at, from, to),
    do: DateTime.compare(at, from) != :lt and DateTime.compare(at, to) == :lt

  defp min_time(a, b), do: if(DateTime.compare(a, b) == :gt, do: b, else: a)
end
