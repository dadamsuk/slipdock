defmodule Slipdock.Pulse do
  @moduledoc """
  A board's flow numbers (#1113), read from the movement ledger
  (`Slipdock.Boards.CardMove`) and the cards' own `completed_at`:

    * `in_progress` — open cards in the board's in-progress (doing) lists;
    * `waiting` — open cards waiting on a person, and since when the oldest
      has waited (`oldest_wait_at`, nil while waits are only a flag and
      carry no time);
    * `done_7d` and `done_today` — cards completed in the last 7 days and
      since midnight UTC, however they were completed: a card ticked off
      without moving is done all the same;
    * `time_to_done` — P50 and P85 seconds from a card's first entry into
      an in-progress list to its completion, over the last 90 days. A card
      that never entered one (history from before the ledger) counts from
      when it was made instead, and is counted in `lead_time`;
    * `moves_24h` — list changes in the last day, `forward` and `back` by
      the two lists' places on the board (a move in from another board is
      neither);
    * `lists` — for each list, the cards that came into it and went out of
      it in the last 7 days, arrivals from other boards included, and its
      usual stay (`usual_stays/1`).

  Nothing here runs unless asked for: the API, MCP `get_board pulse: true`,
  `slipdock pulse`, and the board page only when the owner turned its strip
  on (`show_pulse`).
  """

  import Ecto.Query

  alias Slipdock.Boards.{Board, Card, Column}
  alias Slipdock.Repo

  @window_days 90
  @min_stays 8

  @doc "The days a list's usual stay and the time to done look back over."
  def window_days, do: @window_days

  @doc "The fewest closed stays a usual stay is worked out from."
  def min_stays, do: @min_stays

  @doc """
  The pulse of `board`. `opts[:now]` fixes the clock, for tests.
  """
  def for_board(%Board{id: board_id}, opts \\ []) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    columns = Repo.all(from c in Column, where: c.board_id == ^board_id, order_by: :position)
    doing = for c <- columns, c.category == "doing", do: c.id

    open =
      from c in Card,
        where:
          c.board_id == ^board_id and is_nil(c.archived_at) and is_nil(c.stand_in_for_id) and
            not c.completed

    in_progress = Repo.aggregate(where(open, [c], c.column_id in ^doing), :count)
    waiting = Repo.aggregate(where(open, [c], "waiting" in c.flags), :count)
    {done_7d, done_today} = done_counts(board_id, now)
    ins_outs = ins_outs(board_id, ago(now, 7 * 86_400))
    usual = usual_stays(board_id, columns, now)

    %{
      in_progress: in_progress,
      waiting: waiting,
      oldest_wait_at: nil,
      done_7d: done_7d,
      done_today: done_today,
      time_to_done: time_to_done(board_id, now),
      moves_24h: moves(board_id, ago(now, 86_400)),
      lists:
        Enum.map(columns, fn col ->
          {came, went} = Map.get(ins_outs, col.id, {0, 0})

          %{
            id: col.id,
            name: col.name,
            category: col.category,
            in_7d: came,
            out_7d: went,
            usual_stay: usual[col.id]
          }
        end),
      at: DateTime.truncate(now, :second)
    }
  end

  @doc """
  Each list's usual stay on `board`, in seconds, keyed by list id: the 85th
  percentile of the stays in it that ended in the last 90 days. A list
  with fewer than 8 of them takes the figure for every list of its
  category on the board, held to the same 8; with none of that either, nil.

  A stay is the time from a card coming into the list to the ledger's next
  row for that card, and only when that row takes it out of the list; a
  card still there, or one whose next row was recovered with another
  source, has no closed stay. One query, whatever the size of the board.
  """
  def usual_stays(board, opts \\ [])

  def usual_stays(%Board{id: id, columns: columns}, opts) when is_list(columns),
    do: usual_stays(id, columns, Keyword.get_lazy(opts, :now, &DateTime.utc_now/0))

  def usual_stays(%Board{id: id}, opts) do
    columns = Repo.all(from c in Column, where: c.board_id == ^id)
    usual_stays(id, columns, Keyword.get_lazy(opts, :now, &DateTime.utc_now/0))
  end

  defp usual_stays(_board_id, [], _now), do: %{}

  defp usual_stays(board_id, columns, now) do
    %{rows: rows} =
      Repo.query!(
        """
        WITH ordered AS (
          SELECT m.kind, m.to_column_id, m.inserted_at,
            lead(m.kind) OVER w AS next_kind,
            lead(m.from_column_id) OVER w AS next_from,
            lead(m.inserted_at) OVER w AS next_at
          FROM card_moves m
          WHERE m.card_id IN (SELECT card_id FROM card_moves WHERE board_id = $1)
          WINDOW w AS (PARTITION BY m.card_id ORDER BY m.inserted_at, m.id)
        ), stays AS (
          SELECT o.to_column_id, col.category,
            extract(epoch FROM o.next_at - o.inserted_at)::float8 AS secs
          FROM ordered o
          JOIN columns col ON col.id = o.to_column_id AND col.board_id = $1
          WHERE o.kind IN ('created', 'moved', 'restored')
            AND o.next_kind IN ('moved', 'archived')
            AND o.next_from = o.to_column_id
            AND o.next_at >= $2
        )
        SELECT GROUPING(to_column_id), to_column_id, category, count(*),
          percentile_cont(0.85) WITHIN GROUP (ORDER BY secs)
        FROM stays
        GROUP BY GROUPING SETS ((to_column_id), (category))
        """,
        [board_id, naive(ago(now, @window_days * 86_400))]
      )

    {by_list, by_category} =
      Enum.reduce(rows, {%{}, %{}}, fn
        [0, id, _, n, p85], {lists, cats} -> {Map.put(lists, id, {n, p85}), cats}
        [1, _, cat, n, p85], {lists, cats} -> {lists, Map.put(cats, cat, {n, p85})}
      end)

    Map.new(columns, fn col ->
      figure =
        with {n, p85} when n >= @min_stays <- by_list[col.id] do
          p85
        else
          _ ->
            case col.category && by_category[col.category] do
              {n, p85} when n >= @min_stays -> p85
              _ -> nil
            end
        end

      {col.id, figure && round(figure)}
    end)
  end

  defp done_counts(board_id, now) do
    today = %{now | hour: 0, minute: 0, second: 0, microsecond: {0, 0}}

    from(c in Card,
      where:
        c.board_id == ^board_id and is_nil(c.stand_in_for_id) and c.completed and
          c.completed_at >= ^DateTime.truncate(ago(now, 7 * 86_400), :second),
      select:
        {count(c.id), filter(count(c.id), c.completed_at >= ^DateTime.truncate(today, :second))}
    )
    |> Repo.one()
  end

  defp time_to_done(board_id, now) do
    %{rows: [[p50, p85, cards, lead]]} =
      Repo.query!(
        """
        SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY secs),
          percentile_cont(0.85) WITHIN GROUP (ORDER BY secs),
          count(*), count(*) FILTER (WHERE started_at IS NULL)
        FROM (
          SELECT d.started_at,
            extract(epoch FROM d.completed_at - coalesce(d.started_at, d.inserted_at))::float8 AS secs
          FROM (
            SELECT c.completed_at, c.inserted_at,
              (SELECT min(m.inserted_at) FROM card_moves m
               WHERE m.card_id = c.id AND m.to_category = 'doing'
                 AND m.kind IN ('created', 'moved', 'restored')
                 AND m.inserted_at <= c.completed_at) AS started_at
            FROM cards c
            WHERE c.board_id = $1 AND c.completed AND c.stand_in_for_id IS NULL
              AND c.completed_at >= $2
          ) d
        ) t
        """,
        [board_id, naive(ago(now, @window_days * 86_400))]
      )

    %{p50: p50 && round(p50), p85: p85 && round(p85), cards: cards, lead_time: lead}
  end

  # Forward and back by the lists' places; a list on another board, or one
  # deleted since, has no place here to compare.
  defp moves(board_id, since) do
    %{rows: [[forward, back, total]]} =
      Repo.query!(
        """
        SELECT count(*) FILTER (WHERE t.position > f.position),
          count(*) FILTER (WHERE t.position < f.position), count(*)
        FROM card_moves m
        LEFT JOIN columns f ON f.id = m.from_column_id AND f.board_id = m.board_id
        LEFT JOIN columns t ON t.id = m.to_column_id AND t.board_id = m.board_id
        WHERE m.board_id = $1 AND m.kind = 'moved' AND m.inserted_at >= $2
        """,
        [board_id, naive(since)]
      )

    %{forward: forward, back: back, total: total}
  end

  # Into a list: made there, moved there (from this board or another) or
  # restored there. Out of one: moved away or archived from it.
  defp ins_outs(board_id, since) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT col.id,
          count(m.id) FILTER (WHERE m.to_column_id = col.id
                                AND m.kind IN ('created', 'moved', 'restored')),
          count(m.id) FILTER (WHERE m.from_column_id = col.id
                                AND m.kind IN ('moved', 'archived'))
        FROM columns col
        JOIN card_moves m ON (m.to_column_id = col.id OR m.from_column_id = col.id)
          AND m.inserted_at >= $2
        WHERE col.board_id = $1
        GROUP BY col.id
        """,
        [board_id, naive(since)]
      )

    Map.new(rows, fn [id, came, went] -> {id, {came, went}} end)
  end

  defp ago(now, seconds), do: DateTime.add(now, -seconds, :second)
  defp naive(%DateTime{} = at), do: DateTime.to_naive(at)

  @doc """
  The pulse in plain words, for the board's strip: "6 in progress · 2
  waiting · 23 done this week · usually 1d to done".
  """
  def sentence(pulse, now \\ DateTime.utc_now()) do
    waiting =
      case pulse.oldest_wait_at do
        nil -> "#{pulse.waiting} waiting"
        at -> "#{pulse.waiting} waiting (oldest #{duration(DateTime.diff(now, at))})"
      end

    [
      "#{pulse.in_progress} in progress",
      pulse.waiting > 0 && waiting,
      "#{pulse.done_7d} done this week",
      pulse.time_to_done.p50 && "usually #{duration(pulse.time_to_done.p50)} to done"
    ]
    |> Enum.filter(& &1)
    |> Enum.join(" · ")
  end

  @doc "Seconds as the one unit that reads best: 41m, 3h, 2d."
  def duration(seconds) when seconds < 60, do: "<1m"
  def duration(seconds) when seconds < 3600, do: "#{div(seconds, 60)}m"
  def duration(seconds) when seconds < 86_400, do: "#{div(seconds, 3600)}h"
  def duration(seconds), do: "#{div(seconds, 86_400)}d"
end
