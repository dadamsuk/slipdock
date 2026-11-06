defmodule Slipdock.Quality do
  @parts_migration 20_261_105_170_000

  @moduledoc """
  How well agent work goes on a board (#1796, W-2310 §Quality numbers): the
  numbers that say where the loop goes wrong, beside `Slipdock.Dora` (how
  delivery goes) and `Slipdock.Flow` (how work moves). Like them it is only
  worked out when asked for: REST `GET /api/boards/:board/quality`,
  `slipdock quality <board>` and the Visualise page's Quality section.

  Over the last `days` (30 unless asked), for the board and every board
  beneath it:

    * `verified` — the cards accepted in the window (`verify_state` accepted,
      or merging on a board that ships by pull request, decided in the
      window), and of them `first_time_right`: accepted with no rejection
      (a failed merge counts as one, as `verify_rejections` does) and never
      reopened. `reopened` counts the accepted cards a person reopened at
      some point (the activity log's `reopened` lines): a card that had to
      be reopened was not right first time. `rejections` sums the accepted
      cards' rejections, `per_card` over them, and `in_rework` counts the
      cards rejected in the window and not yet accepted;
    * `areas` — the same per area: the handbook page whose `covers:` take in
      most of a card's lane paths, or `unmapped` for a card with no paths, no
      page covering them, or no handbook. Most rejections first;
    * `jobs` — the runner jobs that finished in the window, and of them the
      timeouts, failures, requeues (`recovery` requeued) and give-ups, each
      `per_100` jobs;
    * `health` — the health incidents raised in the window: `fixed` by the
      monitor, `flagged` to a person (at any point), `cleared` by
      themselves and still `open`;
    * `rejections` (#1798) — the verifiers' rejections in the window, in
      parts: `by_part` (the ask, the bar, the rules, the suite, the Handbook
      line: how many rejections failed each), `by_rule` (each rule id broken,
      with its page and severity from the handbook, most broken first),
      `disputed_lines` (rejections that disputed the `Handbook:` line) and
      `unparted`, the rejections that name no part;
    * `audits` — the audits of accepted cards decided in the window, and how
      many `agreed` and `disagreed`.

  A card keeps only its last verdict (`verify_checks`), so each decision is
  read from the comment `Slipdock.Verified.decide/5` posts for it: a
  `**Rejected** by` comment's `Checks:` lines are its parts. One without
  them, made since verdicts were kept in parts (migration
  `#{@parts_migration}`, as this database ran it), has the parts its reason
  cites (`Checks.from_reason/1`, what the verdict stored); one from before
  that is unparted.

  `previous` holds the window before's `verified` numbers, for a trend.
  """

  import Ecto.Query

  alias Slipdock.Boards.{Activity, Board, Card}
  alias Slipdock.Health.Incident
  alias Slipdock.Repo
  alias Slipdock.Runners.Job

  @default_days 30
  @max_days 365
  @accepted ~w(accepted merging)

  @doc "The window a report looks back over unless asked: #{@default_days} days."
  def default_days, do: @default_days

  @doc """
  The report for `board` and the boards beneath it. Options: `:days`
  (1–#{@max_days}, as an integer or a string; #{@default_days} otherwise) and `:now`.
  """
  def for_board(%Board{} = board, opts \\ []) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    days = opts |> Keyword.get(:days) |> clamp_days()
    since = DateTime.add(now, -days * 86_400, :second)
    prev_since = DateTime.add(since, -days * 86_400, :second)
    ids = tree_ids(board)
    accepted = accepted_cards(ids, prev_since, now)
    reopened = reopened_ids(Enum.map(accepted, & &1.id))

    {current, previous} =
      Enum.split_with(accepted, &(DateTime.compare(&1.verify_at, since) != :lt))

    %{
      days: days,
      since: DateTime.truncate(since, :second),
      until: DateTime.truncate(now, :second),
      verified: Map.put(verified(current, reopened), :in_rework, in_rework(ids, since, now)),
      areas: areas(board, current, reopened),
      jobs: jobs(ids, since, now),
      health: health(board, ids, since, now),
      rejections: rejections(board, ids, since, now),
      audits: audits(ids, since, now),
      previous: verified(previous, reopened)
    }
  end

  # -- Verified cards --------------------------------------------------------------

  defp accepted_cards(ids, from, to) do
    Repo.all(
      from c in Card,
        where:
          c.board_id in ^ids and c.verify_state in @accepted and c.verify_at >= ^from and
            c.verify_at <= ^to and is_nil(c.stand_in_for_id),
        select: %{
          id: c.id,
          paths: c.paths,
          rejections: c.verify_rejections,
          verify_at: c.verify_at
        }
    )
  end

  # The cards a person reopened, ever: the activity log says so.
  defp reopened_ids([]), do: MapSet.new()

  defp reopened_ids(card_ids) do
    Repo.all(
      from a in Activity,
        where: a.card_id in ^card_ids and like(a.message, "reopened “%"),
        distinct: true,
        select: a.card_id
    )
    |> MapSet.new()
  end

  defp in_rework(ids, from, to) do
    Repo.aggregate(
      from(c in Card,
        where:
          c.board_id in ^ids and c.verify_state == "rejected" and c.verify_at >= ^from and
            c.verify_at <= ^to and is_nil(c.archived_at)
      ),
      :count
    )
  end

  defp verified(cards, reopened) do
    accepted = length(cards)
    rejections = Enum.sum_by(cards, &(&1.rejections || 0))
    ftr = Enum.count(cards, &first_time_right?(&1, reopened))

    %{
      accepted: accepted,
      first_time_right: ftr,
      rate: rate(ftr, accepted),
      rejections: rejections,
      per_card: ratio(rejections, accepted),
      reopened: Enum.count(cards, &MapSet.member?(reopened, &1.id))
    }
  end

  defp first_time_right?(card, reopened),
    do: (card.rejections || 0) == 0 and not MapSet.member?(reopened, card.id)

  # Each accepted card in its area: the handbook page covering most of its
  # paths, or unmapped.
  defp areas(board, cards, reopened) do
    handbook = Slipdock.Handbook.find(board)

    cards
    |> Enum.group_by(&area(handbook, &1.paths))
    |> Enum.map(fn {area, cards} ->
      v = verified(cards, reopened)

      Map.merge(area, %{
        cards: v.accepted,
        first_time_right: v.first_time_right,
        rate: v.rate,
        rejections: v.rejections,
        per_card: v.per_card
      })
    end)
    |> Enum.sort_by(&{-&1.rejections, -&1.cards, &1.code == nil, &1.title})
  end

  @unmapped %{code: nil, title: "unmapped"}

  defp area(nil, _paths), do: @unmapped
  defp area(_handbook, paths) when paths in [nil, []], do: @unmapped

  defp area(handbook, paths) do
    case Slipdock.Handbook.pages_for(handbook, paths) do
      [%{code: code, title: title} | _] -> %{code: code, title: title}
      [] -> @unmapped
    end
  end

  # -- Jobs ------------------------------------------------------------------------

  defp jobs(ids, from, to) do
    rows =
      Repo.all(
        from j in Job,
          where: j.board_id in ^ids and j.finished_at >= ^from and j.finished_at <= ^to,
          select: {j.status, j.recovery}
      )

    total = length(rows)

    counts = %{
      timeouts: Enum.count(rows, &(elem(&1, 0) == "timeout")),
      failed: Enum.count(rows, &(elem(&1, 0) == "failed")),
      requeues:
        Enum.count(rows, &Enum.member?(["requeued", "requeued_before_done"], elem(&1, 1))),
      gave_up: Enum.count(rows, &(elem(&1, 1) == "gave_up"))
    }

    Map.merge(counts, %{
      jobs: total,
      per_100: Map.new(counts, fn {k, n} -> {k, per_100(n, total)} end)
    })
  end

  # -- Health ------------------------------------------------------------------------

  # A root board's incidents are filed on it; a sub-board's are the ones
  # about its cards.
  defp health(board, ids, from, to) do
    card_ids = from(c in Card, where: c.board_id in ^ids, select: c.id)

    rows =
      Repo.all(
        from i in Incident,
          where:
            (i.board_id == ^board.id or i.card_id in subquery(card_ids)) and
              i.inserted_at >= ^from and i.inserted_at <= ^to,
          select: {i.status, i.flagged_at}
      )

    %{
      incidents: length(rows),
      fixed: Enum.count(rows, &(elem(&1, 0) == "fixed")),
      flagged: Enum.count(rows, &(elem(&1, 1) != nil or elem(&1, 0) == "flagged")),
      cleared: Enum.count(rows, &(elem(&1, 0) == "cleared")),
      open: Enum.count(rows, &(elem(&1, 0) == "open"))
    }
  end

  # -- Rejections in parts ------------------------------------------------------

  @part_order ~w(ask bar rules suite handbook_line)

  defp rejections(board, ids, from, to) do
    since_parts = parts_since()

    decisions =
      for {body, at} <- decision_comments(ids, "**Rejected** by%", from, to),
          do: rejection_parts(body, at, since_parts)

    rules = handbook_rules(board)
    count = fn kind -> Enum.count(decisions, &Enum.any?(&1, fn p -> elem(p, 0) == kind end)) end

    %{
      rejections: length(decisions),
      unparted: Enum.count(decisions, &(&1 == [])),
      by_part:
        for(kind <- @part_order, (n = count.(kind)) > 0, do: %{part: kind, count: n})
        |> Enum.sort_by(&(-&1.count)),
      by_rule: by_rule(decisions, rules),
      disputed_lines: count.("handbook_line")
    }
  end

  defp by_rule(decisions, rules) do
    known = Map.new(rules, &{String.upcase(&1.id), &1})

    decisions
    |> Enum.flat_map(fn parts -> for {"rules", id} <- parts, do: id end)
    |> Enum.frequencies()
    |> Enum.map(fn {id, n} ->
      rule = known[id]

      %{
        id: id,
        count: n,
        severity: rule && rule.severity,
        page: rule && %{code: rule.page, title: rule.page_title}
      }
    end)
    |> Enum.sort_by(&{-&1.count, &1.id})
  end

  defp handbook_rules(board) do
    case Slipdock.Handbook.find(board) do
      nil -> []
      handbook -> Slipdock.Handbook.Rules.rules(handbook)
    end
  end

  defp audits(ids, from, to) do
    bodies = decision_comments(ids, "**Audit: %", from, to)

    agreed =
      Enum.count(bodies, fn {body, _} -> String.starts_with?(body, "**Audit: agrees**") end)

    disagreed =
      Enum.count(bodies, fn {body, _} -> String.starts_with?(body, "**Audit: disagrees**") end)

    %{audits: agreed + disagreed, agreed: agreed, disagreed: disagreed}
  end

  defp decision_comments(ids, pattern, from, to) do
    Repo.all(
      from cm in Slipdock.Boards.Comment,
        join: c in Card,
        on: c.id == cm.card_id,
        where:
          c.board_id in ^ids and like(cm.body, ^pattern) and cm.inserted_at >= ^from and
            cm.inserted_at <= ^to,
        order_by: [asc: cm.id],
        select: {cm.body, cm.inserted_at}
    )
  end

  # When this database began keeping verdicts in parts; nil if it never ran
  # the migration (then no rejection is held to be from before it).
  defp parts_since do
    case Repo.query!("SELECT inserted_at FROM schema_migrations WHERE version = $1", [
           @parts_migration
         ]).rows do
      [[%NaiveDateTime{} = at]] -> DateTime.from_naive!(at, "Etc/UTC")
      _ -> nil
    end
  end

  @doc """
  The failing parts of one rejection, from the comment it was posted as
  (`body`, at `at`): `[{"bar", "2"}, {"rules", "UX-4"}, {"ask", nil}, …]`,
  `[]` when it names none. `since_parts` is when verdicts began to be kept
  in parts: a comment from before it, without a `Checks:` block, is
  unparted whatever its reason says.
  """
  def rejection_parts(body, at, since_parts) when is_binary(body) do
    case String.split(body, "\n\nChecks:\n", parts: 2) do
      [_, lines] ->
        lines |> String.split("\n") |> Enum.flat_map(&checks_line/1) |> Enum.uniq()

      [_] ->
        if since_parts && DateTime.compare(at, since_parts) == :lt,
          do: [],
          else: body |> reason() |> Slipdock.Verified.Checks.from_reason() |> map_parts()
    end
  end

  # The reason: what follows the comment's opening line.
  defp reason(body), do: body |> String.split("\n\n", parts: 2) |> Enum.at(1, "")

  # One `- label: result[ — why]` line, as `Checks.lines/1` wrote it.
  defp checks_line(line) do
    case Regex.run(~r/^\s*-\s+(.+?):\s+(.+?)(?:\s+—\s.*)?\s*$/u, line) do
      [_, label, result] -> line_part(label, result)
      _ -> []
    end
  end

  defp line_part("the ask", "misses"), do: [{"ask", nil}]
  defp line_part("Handbook line", "disputed"), do: [{"handbook_line", nil}]

  defp line_part("suite", result) do
    if Slipdock.Verified.Checks.failing_result?(result), do: [{"suite", nil}], else: []
  end

  defp line_part("bar " <> item, "fail"), do: [{"bar", String.trim(item)}]

  defp line_part(label, "broken") do
    case Regex.run(~r/^([A-Z][A-Z0-9]*-\d+)\b/i, label) do
      [_, id] -> [{"rules", String.upcase(id)}]
      _ -> []
    end
  end

  defp line_part(_label, _result), do: []

  # A stored verdict's failing parts, in the same shape.
  defp map_parts(checks) do
    ask = if checks["ask"] == "misses", do: [{"ask", nil}], else: []
    line = if checks["handbook_line"] == "disputed", do: [{"handbook_line", nil}], else: []
    bar = for %{"result" => "fail", "item" => i} <- checks["bar"] || [], do: {"bar", i}
    rules = for %{"result" => "broken", "id" => id} <- checks["rules"] || [], do: {"rules", id}
    ask ++ bar ++ rules ++ line
  end

  # -- Words -------------------------------------------------------------------------

  @doc """
  The report as one line: first-time-right, rejections per card, and the
  job outcomes when there were jobs.
  """
  def sentence(%{verified: v, jobs: j, days: days} = r) do
    verified =
      if v.accepted == 0,
        do: "no cards accepted",
        else:
          "#{pct(v.rate)} right first time (#{v.first_time_right} of #{v.accepted})" <>
            trend(v.rate, r.previous.rate) <> " · #{v.per_card} rejections per card"

    jobs =
      if j.jobs == 0,
        do: [],
        else: [
          "#{j.jobs} jobs: #{j.per_100.timeouts} timeouts, #{j.per_100.requeues} requeues " <>
            "and #{j.per_100.gave_up} give-ups per 100"
        ]

    Enum.join(["#{days}d: " <> verified | jobs], " · ")
  end

  defp trend(_now, nil), do: ""
  defp trend(nil, _before), do: ""
  defp trend(same, same), do: ""
  defp trend(now, before) when now > before, do: " ↑"
  defp trend(_now, _before), do: " ↓"

  @doc "A share as a whole percentage, or – when there is none."
  def pct(nil), do: "–"
  def pct(r), do: "#{round(r * 100)}%"

  # -- Bits --------------------------------------------------------------------------

  @doc "The ids of `board` and every board beneath it, however deep."
  def tree_ids(%Board{id: id}), do: tree_ids([id], [id])

  defp tree_ids([], acc), do: acc

  defp tree_ids(frontier, acc) do
    next =
      Repo.all(
        from b in Board,
          join: c in Card,
          on: b.parent_card_id == c.id,
          where: c.board_id in ^frontier and b.id not in ^acc,
          select: b.id
      )

    tree_ids(next, acc ++ next)
  end

  defp rate(_n, 0), do: nil
  defp rate(n, total), do: Float.round(n / total, 3)

  defp ratio(_n, 0), do: nil
  defp ratio(n, total), do: Float.round(n / total, 2)

  defp per_100(_n, 0), do: nil
  defp per_100(n, total), do: Float.round(n * 100 / total, 1)

  defp clamp_days(nil), do: @default_days

  defp clamp_days(d) when is_binary(d) do
    case Integer.parse(d) do
      {n, ""} -> clamp_days(n)
      _ -> @default_days
    end
  end

  defp clamp_days(d) when is_integer(d), do: d |> max(1) |> min(@max_days)
  defp clamp_days(_), do: @default_days
end
