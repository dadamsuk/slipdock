defmodule Slipdock.Overseer.Checks.Slow do
  @moduledoc """
  Slow (#2068), two ways:

    * a card in a doing list longer than the board's P85 time to done for
      cards of its profile (or, with fewer than `Slipdock.Pulse.min_stays/0`
      of those done in the window, for every card on its board), counted
      from its first entry into a doing list, as the pulse counts;
    * a running job whose heartbeat is live (its lease not run out) but
      whose step hasn't changed in `step_minutes/0` minutes.

  Each clears when the card leaves the doing list or is done, or the job
  reports a new step or ends.
  """
  @behaviour Slipdock.Overseer.Check

  import Ecto.Query

  require Slipdock.Flow.DoingList, as: DoingList

  alias Slipdock.Boards.{Card, CardMove, Column}
  alias Slipdock.Overseer.Check
  alias Slipdock.Repo
  alias Slipdock.Runners.Job

  @step_minutes 30

  @doc "Minutes a running job's step may stay the same before it is slow."
  def step_minutes, do: @step_minutes

  @impl true
  def key, do: "slow"

  @impl true
  def label, do: "Slow"

  @impl true
  def find(ctx), do: slow_cards(ctx) ++ slow_jobs(ctx)

  defp slow_cards(ctx) do
    started =
      from(m in CardMove,
        where:
          DoingList.doing?(m.to_category, m.to_column_name) and m.kind in ^CardMove.entry_kinds(),
        group_by: m.card_id,
        select: %{card_id: m.card_id, at: min(m.inserted_at)}
      )

    cards =
      ctx
      |> Check.live_cards()
      |> join(:inner, [c], col in Column,
        on: col.id == c.column_id and DoingList.doing?(col.category, col.name)
      )
      |> join(:inner, [c], s in subquery(started), on: s.card_id == c.id)
      |> select([c, _col, s], %{
        id: c.id,
        title: c.title,
        board_id: c.board_id,
        profile: c.profile,
        at: s.at
      })
      |> Repo.all()

    p85s = p85s(cards |> Enum.map(& &1.board_id) |> Enum.uniq(), ctx.now)

    Enum.flat_map(cards, fn c ->
      age = DateTime.diff(ctx.now, c.at)

      case p85_for(p85s, c) do
        {p85, n, what} when age > p85 ->
          [
            %{
              subject: "card:#{c.id}:slow",
              card_id: c.id,
              title:
                "##{c.id} is slow: in flight #{Check.duration(age)}, P85 #{Check.duration(p85)}",
              why:
                "#{Check.ref(c)} has been in progress #{Check.duration(age)}; #{what} on its " <>
                  "board usually finish within #{Check.duration(p85)} (P85 of #{n}).",
              todo:
                "See whether it is stuck, bigger than it looked, or waiting on something " <>
                  "nobody has said: unblock it, split it, or say on it why it is taking longer."
            }
          ]

        _ ->
          []
      end
    end)
  end

  # The P85 seconds to done per board and per {board, profile}, over the
  # pulse's window, where enough cards were done to say.
  defp p85s([], _now), do: %{}

  defp p85s(board_ids, now) do
    since = DateTime.add(now, -Slipdock.Pulse.window_days() * 86_400, :second)

    started =
      from(m in CardMove,
        where:
          DoingList.doing?(m.to_category, m.to_column_name) and m.kind in ^CardMove.entry_kinds(),
        group_by: m.card_id,
        select: %{card_id: m.card_id, at: min(m.inserted_at)}
      )

    rows =
      from(c in Card,
        join: s in subquery(started),
        on: s.card_id == c.id,
        where: c.board_id in ^board_ids and c.completed and c.completed_at >= ^since,
        where: is_nil(c.stand_in_for_id) and s.at <= c.completed_at,
        select:
          {c.board_id, c.profile,
           fragment("extract(epoch FROM ? - ?)::float8", c.completed_at, s.at)}
      )
      |> Repo.all()

    by_board = Enum.group_by(rows, &elem(&1, 0), &elem(&1, 2))
    by_profile = Enum.group_by(rows, &{elem(&1, 0), elem(&1, 1)}, &elem(&1, 2))

    Map.merge(stats(by_board), stats(by_profile))
  end

  defp stats(groups) do
    for {key, secs} <- groups, length(secs) >= Slipdock.Pulse.min_stays(), into: %{} do
      {key, {percentile(secs, 0.85), length(secs)}}
    end
  end

  # Linear interpolation between ranks, as Postgres's percentile_cont does.
  @doc false
  def percentile(values, p) do
    sorted = Enum.sort(values)
    rank = p * (length(sorted) - 1)
    lo = floor(rank)
    hi = ceil(rank)
    a = Enum.at(sorted, lo)
    b = Enum.at(sorted, hi)
    round(a + (b - a) * (rank - lo))
  end

  defp p85_for(p85s, %{board_id: board, profile: profile}) do
    case {profile && p85s[{board, profile}], p85s[board]} do
      {{p85, n}, _} -> {p85, n, "#{profile} cards"}
      {_, {p85, n}} -> {p85, n, "cards"}
      _ -> nil
    end
  end

  defp slow_jobs(%{root: root, now: now}) do
    cutoff = DateTime.add(now, -@step_minutes * 60, :second)

    from(j in Job,
      join: c in Card,
      on: c.id == j.card_id,
      where: j.root_board_id == ^root.id and j.status == "running",
      where: j.lease_expires_at > ^now,
      where: coalesce(j.step_at, j.started_at) <= ^cutoff,
      select: %{
        id: j.id,
        step: j.step,
        at: coalesce(j.step_at, j.started_at),
        runner: j.runner_name,
        card: %{id: c.id, title: c.title}
      }
    )
    |> Repo.all()
    |> Enum.map(fn j ->
      same = Check.duration(DateTime.diff(now, j.at))
      step = if j.step, do: "“#{String.slice(j.step, 0, 120)}”", else: "no step at all"

      %{
        subject: "job:#{j.id}:step",
        card_id: j.card.id,
        title: "Job ##{j.id} on ##{j.card.id}: the same step for #{same}",
        why:
          "Job ##{j.id} (#{j.runner || "a runner"}) on #{Check.ref(j.card)} is alive, its " <>
            "heartbeat current, but has reported #{step} for #{same}.",
        todo:
          "Open the job's log: the agent may be going round, or waiting on a prompt " <>
            "nobody can see. Cancel it if it is getting nowhere."
      }
    end)
  end
end
