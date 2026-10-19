defmodule Slipdock.Dora do
  @moduledoc """
  A board's delivery performance (#1134), the DORA way, read from the
  deployments ledger (`Slipdock.Deployments`), its incident cards
  (`Slipdock.Deployments.Incidents`) and the movement ledger. Like
  `Slipdock.Pulse` it is only worked out when asked for: the API, MCP
  `get_board dora: true`, `slipdock dora`, and the board page's strip while
  the board's delivery metrics are on.

  For one environment over the last `days` (30 unless asked):

    * `deployment_frequency` — succeeded deploys, per day and per week;
    * `lead_time` — P50/P85 seconds from a commit to the succeeded deploy
      that shipped it;
    * `change_failure_rate` — the share of finished deploys that were failed
      changes (see `Slipdock.Deployments.Incidents.failures/3`);
    * `time_to_restore` — P50/P85 seconds of the restores that ended in the
      window, incidents and failed deploys both;
    * `rework_rate` — the share of finished deploys whose commits name an
      incident card;
    * `idea_to_production` — P50/P85 seconds from a card first entering an
      in-progress list (else from when it was made, counted in
      `from_created`) to the first succeeded deploy whose commits name it,
      for the cards first shipped in the window. What a board knows that a
      pipeline tool doesn't.

  Each has its DORA band (`elite`, `high`, `medium`, `low`) where DORA
  defines one, and `previous` holds the window before for a trend.
  """

  import Ecto.Query

  alias Slipdock.Boards.{Board, Card, CardMove}
  alias Slipdock.Deployments
  alias Slipdock.Deployments.Incidents
  alias Slipdock.Repo

  @default_days 30
  @max_days 365

  @doc "The window a report looks back over unless asked: #{@default_days} days."
  def default_days, do: @default_days

  @doc """
  The report for `board`: `{:ok, report}`, or `{:error, :off}` while its
  delivery metrics are off. Options: `:environment` (production, else the
  environment deployed to most), `:days` (1–#{@max_days}) and `:now`.
  """
  def for_board(%Board{} = board, opts \\ []) do
    if Deployments.enabled?(board), do: {:ok, report(board, opts)}, else: {:error, :off}
  end

  defp report(board, opts) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    days = opts |> Keyword.get(:days) |> clamp_days()
    environment = opts[:environment] || default_environment(board)
    since = DateTime.add(now, -days * 86_400, :second)
    prev_since = DateTime.add(since, -days * 86_400, :second)

    # Everything a window's numbers can hang on: the window before (for the
    # trend), and a hotfix window's worth before that.
    lookback = DateTime.add(prev_since, -(board.hotfix_window_hours || 24) * 3600, :second)
    deploys = Deployments.list(board, environment: environment, since: lookback)
    incidents = Incidents.cards(board)
    failures = Incidents.failures(board, deploys, incidents)
    restores = Incidents.restores(board, deploys, incidents)
    incident_ids = MapSet.new(incidents, & &1.id)

    ctx = %{
      board: board,
      environment: environment,
      deploys: deploys,
      failures: failures,
      restores: restores,
      incident_ids: incident_ids
    }

    current = window(ctx, since, now, days)
    previous = window(ctx, prev_since, since, days)

    Map.merge(current, %{
      enabled: true,
      environment: environment,
      environments: Deployments.environments(board),
      days: days,
      since: DateTime.truncate(since, :second),
      until: DateTime.truncate(now, :second),
      last_deploy: last_deploy(Deployments.latest(board, environment)),
      previous: previous
    })
  end

  defp window(ctx, from, to, days) do
    in_window = Enum.filter(ctx.deploys, &within?(&1.started_at, from, to))
    succeeded = Enum.filter(in_window, &(&1.status == "succeeded"))
    finished = Enum.filter(in_window, &(&1.status in ["succeeded", "failed"]))
    failed = Enum.count(finished, &Map.has_key?(ctx.failures, &1.id))
    rework = Enum.count(finished, &Incidents.rework?(&1, ctx.incident_ids))

    restores =
      for r <- ctx.restores, within?(r.to, from, to), do: r.seconds

    lead_times =
      for d <- succeeded,
          c <- d.commits || [],
          at = parse_time(c["committed_at"]),
          at != nil,
          do: max(DateTime.diff(d.finished_at || d.started_at, at), 0)

    per_day = length(succeeded) / days
    idea = idea_to_production(ctx, from, to)
    lead = percentiles(lead_times)
    restore = percentiles(restores)
    cfr = rate(failed, length(finished))

    %{
      deployment_frequency: %{
        deploys: length(succeeded),
        per_day: Float.round(per_day, 2),
        per_week: Float.round(per_day * 7, 1),
        band: frequency_band(per_day)
      },
      lead_time: Map.merge(lead, %{commits: length(lead_times), band: lead_time_band(lead.p50)}),
      change_failure_rate: %{
        failed: failed,
        deploys: length(finished),
        rate: cfr,
        band: failure_band(cfr)
      },
      time_to_restore:
        Map.merge(restore, %{restores: length(restores), band: restore_band(restore.p50)}),
      rework_rate: %{
        rework: rework,
        deploys: length(finished),
        rate: rate(rework, length(finished))
      },
      idea_to_production: idea
    }
  end

  # The cards whose first succeeded deploy to this environment was in the
  # window, from their first entry into an in-progress list.
  defp idea_to_production(ctx, from, to) do
    window_cards =
      ctx.deploys
      |> Enum.filter(&(&1.status == "succeeded" and within?(&1.started_at, from, to)))
      |> Enum.flat_map(& &1.card_ids)
      |> Enum.uniq()

    shipped = first_shipped(ctx.board, ctx.environment, window_cards)
    shipped = for {id, at} <- shipped, within?(at, from, to), into: %{}, do: {id, at}
    started = first_started(Map.keys(shipped))

    spans =
      for {id, shipped_at} <- shipped, {at, how} = started[id], at != nil do
        {max(DateTime.diff(shipped_at, at), 0), how}
      end

    spans
    |> Enum.map(&elem(&1, 0))
    |> percentiles()
    |> Map.merge(%{
      cards: length(spans),
      from_created: Enum.count(spans, &(elem(&1, 1) == :created))
    })
  end

  # When each card was first in a succeeded deploy to the environment, ever.
  defp first_shipped(_board, _environment, []), do: %{}

  defp first_shipped(board, environment, ids) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT u.id, min(coalesce(d.finished_at, d.started_at))
        FROM deployments d CROSS JOIN LATERAL unnest(d.card_ids) AS u(id)
        WHERE d.board_id = $1 AND d.environment = $2 AND d.status = 'succeeded'
          AND u.id = ANY($3)
        GROUP BY u.id
        """,
        [board.id, environment, ids]
      )

    Map.new(rows, fn [id, at] -> {id, utc(at)} end)
  end

  defp utc(%NaiveDateTime{} = at), do: DateTime.from_naive!(at, "Etc/UTC")
  defp utc(%DateTime{} = at), do: at

  # Each card's first entry into an in-progress list, else when it was made.
  defp first_started([]), do: %{}

  defp first_started(ids) do
    doing =
      Repo.all(
        from m in CardMove,
          where: m.card_id in ^ids and m.to_category == "doing",
          group_by: m.card_id,
          select: {m.card_id, min(m.inserted_at)}
      )
      |> Map.new()

    Repo.all(from c in Card, where: c.id in ^ids, select: {c.id, c.inserted_at})
    |> Map.new(fn {id, made} ->
      case doing[id] do
        nil -> {id, {made, :created}}
        at -> {id, {at, :doing}}
      end
    end)
  end

  defp last_deploy(nil), do: nil

  defp last_deploy(d) do
    %{id: d.id, sha: d.sha, tag: d.tag, status: d.status, at: d.finished_at || d.started_at}
  end

  @doc "production when the board deploys there, else where it deploys most."
  def default_environment(board) do
    case Deployments.environments(board) do
      [] -> "production"
      envs -> if "production" in envs, do: "production", else: hd(envs)
    end
  end

  # -- Numbers -----------------------------------------------------------------

  @doc "P50 and P85 of a list of seconds, interpolated as percentile_cont does; nil when empty."
  def percentiles([]), do: %{p50: nil, p85: nil}

  def percentiles(values) do
    sorted = Enum.sort(values)
    %{p50: percentile(sorted, 0.5), p85: percentile(sorted, 0.85)}
  end

  defp percentile([only], _p), do: round(only)

  defp percentile(sorted, p) do
    rank = p * (length(sorted) - 1)
    lo = floor(rank)
    hi = min(lo + 1, length(sorted) - 1)
    a = Enum.at(sorted, lo)
    b = Enum.at(sorted, hi)
    round(a + (b - a) * (rank - lo))
  end

  defp rate(_n, 0), do: nil
  defp rate(n, total), do: Float.round(n / total, 3)

  @day 86_400

  @doc "DORA's band for deploys per day: on demand, daily–weekly, weekly–monthly, less."
  def frequency_band(per_day) when per_day >= 1, do: "elite"
  def frequency_band(per_day) when per_day * 7 >= 1, do: "high"
  def frequency_band(per_day) when per_day * 30 >= 1, do: "medium"
  def frequency_band(per_day) when per_day > 0, do: "low"
  def frequency_band(_), do: nil

  @doc "DORA's band for lead time (P50 seconds): under a day, a week, a month, more."
  def lead_time_band(nil), do: nil
  def lead_time_band(s) when s < @day, do: "elite"
  def lead_time_band(s) when s < 7 * @day, do: "high"
  def lead_time_band(s) when s < 30 * @day, do: "medium"
  def lead_time_band(_), do: "low"

  @doc "DORA's band for the change failure rate: 5%, 10%, 15%, more."
  def failure_band(nil), do: nil
  def failure_band(r) when r <= 0.05, do: "elite"
  def failure_band(r) when r <= 0.10, do: "high"
  def failure_band(r) when r <= 0.15, do: "medium"
  def failure_band(_), do: "low"

  @doc "DORA's band for time to restore (P50 seconds): under an hour, a day, a week, more."
  def restore_band(nil), do: nil
  def restore_band(s) when s < 3600, do: "elite"
  def restore_band(s) when s < @day, do: "high"
  def restore_band(s) when s < 7 * @day, do: "medium"
  def restore_band(_), do: "low"

  # -- Words ---------------------------------------------------------------------

  @doc """
  The report as one line for the board's strip: what matters, with an
  arrow where the window before was different.
  """
  def sentence(r) do
    f = r.deployment_frequency
    p = r.previous

    "#{r.environment}, #{r.days}d: " <>
      ([
         "#{f.deploys} deploy#{if f.deploys == 1, do: "", else: "s"}#{trend(f.deploys, p.deployment_frequency.deploys)}" <>
           band_text(f.band),
         r.lead_time.p50 &&
           "lead time #{duration(r.lead_time.p50)}#{trend(r.lead_time.p50, p.lead_time.p50)}" <>
             band_text(r.lead_time.band),
         r.change_failure_rate.rate &&
           "#{pct(r.change_failure_rate.rate)} failed#{trend(r.change_failure_rate.rate, p.change_failure_rate.rate)}" <>
             band_text(r.change_failure_rate.band),
         r.time_to_restore.p50 &&
           "restored in #{duration(r.time_to_restore.p50)}#{trend(r.time_to_restore.p50, p.time_to_restore.p50)}" <>
             band_text(r.time_to_restore.band),
         r.rework_rate.rate && r.rework_rate.rework > 0 && "#{pct(r.rework_rate.rate)} rework",
         r.idea_to_production.p50 &&
           "idea to production #{duration(r.idea_to_production.p50)}#{trend(r.idea_to_production.p50, p.idea_to_production.p50)}"
       ]
       |> Enum.filter(& &1)
       |> Enum.join(" · "))
  end

  # ↑ or ↓ when it moved, and the arrow says which way, not whether it's good.
  defp trend(_now, nil), do: ""
  defp trend(nil, _before), do: ""
  defp trend(same, same), do: ""
  defp trend(now, before) when now > before, do: " ↑"
  defp trend(_now, _before), do: " ↓"

  defp band_text(nil), do: ""
  defp band_text(band), do: " (#{band})"

  defp pct(r), do: "#{round(r * 100)}%"

  defdelegate duration(seconds), to: Slipdock.Pulse

  # -- Bits ------------------------------------------------------------------------

  defp clamp_days(nil), do: @default_days

  defp clamp_days(d) when is_binary(d) do
    case Integer.parse(d) do
      {n, ""} -> clamp_days(n)
      _ -> @default_days
    end
  end

  defp clamp_days(d) when is_integer(d), do: d |> max(1) |> min(@max_days)
  defp clamp_days(_), do: @default_days

  defp within?(nil, _from, _to), do: false

  defp within?(at, from, to),
    do: DateTime.compare(at, from) != :lt and DateTime.compare(at, to) == :lt

  defp parse_time(nil), do: nil

  defp parse_time(at) when is_binary(at) do
    case DateTime.from_iso8601(at) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end
end
