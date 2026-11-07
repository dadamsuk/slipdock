defmodule Slipdock.LeadTime do
  @moduledoc """
  Where a card's time went (#1876): its lead time, from creation to the
  first deploy that shipped it (or its completion, or now while it is
  open), broken into phases from what the server recorded.

  Every second of that span goes to one phase. Each recorded thing claims
  the time it covers, and where several overlap the first of these wins:

    1. `:merge` — a merge job, queued to finished
    2. `:verify` — a verify job running (audits aside: they come after)
    3. `:verification_wait` — a verify job queued, not yet claimed
    4. `:waiting_on_person` — a wait on a person, opened to closed
    5. `:ci` — a CI run: from a `Build started` comment (or a job step
       saying CI started) to the `Build failed` / `Build passed` that ends
       it, or to the end of the job it ran in when nothing did
    6. `:rework` — a work job running after the card was rejected
    7. `:build` — a work job running (and, on a card no job was ever sent
       on, its time in a doing list)
    8. `:waiting_for_runner` — a work job queued, or the card sitting in
       its board's ready list; `held_by` names the jobs that kept the pool
       busy meanwhile
    9. `:deploy` — completed or merged, until the first deploy naming it
    10. `:backlog` — any other list that isn't doing, done or dropped

  Time nothing covers is `:unexplained`, a phase of its own rather than
  spread over the others.

  Beside the time, `cost` (#1954): what the card's jobs spent, from their
  logs (`Slipdock.Runners.JobCost`), in total and by phase. A job's cost
  goes to the phase its run is in: `:build`, `:rework`, `:verify` (audits
  too) or `:merge`, so CI watched inside a build job counts as building.
  Each is `model_seconds`, `tool_seconds`, `tokens` (nil when no log
  carried usage) and `jobs`; `cost` is nil when no job sent a log. The numbers are worked out here so the card chat
  quotes them rather than doing sums (`card_lead_time`).
  """

  import Ecto.Query

  alias Slipdock.{Boards, CardTimeline, Repo, Verified}
  alias Slipdock.Boards.{Board, Card, Column, Comment}
  alias Slipdock.Deployments.Deployment
  alias Slipdock.Runners.{Job, JobCost}
  alias SlipdockWeb.APIGuide

  @phases [
    :backlog,
    :waiting_for_runner,
    :build,
    :ci,
    :waiting_on_person,
    :verification_wait,
    :verify,
    :rework,
    :merge,
    :deploy,
    :unexplained
  ]

  @precedence [
    :merge,
    :verify,
    :verification_wait,
    :waiting_on_person,
    :ci,
    :rework,
    :build,
    :waiting_for_runner,
    :deploy,
    :backlog
  ]

  @rank @precedence |> Enum.with_index() |> Map.new()

  @build_event ~r/^\W{0,3}Build (started|failed|passed)\b/im

  @doc "The phases, in the order a card usually goes through them."
  def phases, do: @phases

  @doc """
  The lead time of `card`. Options: `:now` (a `DateTime`, for open spans).

  Returns a map: `from`, `to`, `ends` (`:deployed`, `:completed` or
  `:open`), `done_at`, `deployed_at`, `seconds`, `done_seconds` (to `done_at`), `totals` (phase =>
  seconds, every phase present), `segments` (in order: `phase`, `from`,
  `to`, `seconds`, `note`, `refs`, and on waiting segments `held_by`),
  `jobs` (how many were sent on it) and `cost` (see above).
  """
  def for_card(%Card{} = card, opts \\ []) do
    now = opts |> Keyword.get(:now, DateTime.utc_now()) |> sec()
    timeline = CardTimeline.for_card(card, now: now)
    jobs = jobs(card)
    parent_jobs = card |> ancestor_ids() |> work_jobs_on()
    comments = comments(card)
    rejected_at = rejected_at(comments)
    done_at = done_at(card, jobs)
    deployed_at = deployed_at(card, done_at)
    from = sec(card.inserted_at)
    to = deployed_at || done_at || now

    intervals =
      job_intervals(jobs, rejected_at, now) ++
        ci_intervals(comments, jobs, to) ++
        wait_intervals(timeline.waits) ++
        stay_intervals(timeline.stays, jobs, parent_jobs) ++
        deploy_interval(done_at, deployed_at)

    segments =
      intervals
      |> sweep(from, to)
      |> Enum.map(&held_by(&1, card, jobs ++ parent_jobs))

    %{
      card_id: card.id,
      from: from,
      to: to,
      ends: ends(deployed_at, done_at),
      done_at: done_at,
      deployed_at: deployed_at,
      seconds: max(DateTime.diff(to, from), 0),
      done_seconds: done_at && max(DateTime.diff(done_at, from), 0),
      totals: totals(segments),
      segments: segments,
      jobs: length(jobs),
      cost: cost(jobs, rejected_at)
    }
  end

  @doc """
  An epic's lead time: its own (`card`), each subcard's (`subcards`, in
  board order) and the subcards' phases added up (`total`, with `seconds`
  and `totals`). A card with no subcards has `subcards: []`. The total's
  `cost` adds the epic's own jobs (which often build its subcards) to its
  subcards' costs.
  """
  def for_epic(%Card{} = card, opts \\ []) do
    own = for_card(card, opts)
    subs = card |> subcards() |> Enum.map(&{&1, for_card(&1, opts)})

    total = %{
      seconds: subs |> Enum.map(&elem(&1, 1).seconds) |> Enum.sum(),
      totals:
        Enum.reduce(subs, Map.new(@phases, &{&1, 0}), fn {_card, lt}, acc ->
          Map.merge(acc, lt.totals, fn _k, a, b -> a + b end)
        end),
      cost: sum_costs([own.cost | Enum.map(subs, &elem(&1, 1).cost)])
    }

    %{card: own, subcards: subs, total: total}
  end

  @doc """
  The short form every door shows beside a card (#1954): `seconds`, `ends`,
  `phases` (the phases with any time, phase => seconds) and `cost` (as in
  `for_card/2`, nil when no job sent a log). On an epic, `rollup` adds its
  subcards: how many (`subcards`), their lead times added up (`seconds`)
  and the cost of the epic's own jobs and theirs together (`cost`); nil on
  a card with no subcards.
  """
  def brief(%Card{} = card, opts \\ []) do
    %{card: own, subcards: subs, total: total} = for_epic(card, opts)

    %{
      seconds: own.seconds,
      ends: own.ends,
      phases: for({phase, s} <- own.totals, s > 0, into: %{}, do: {phase, s}),
      cost: own.cost,
      rollup:
        if(subs != [], do: %{subcards: length(subs), seconds: total.seconds, cost: total.cost})
    }
  end

  @doc """
  `brief/2` for a card a runner has worked (a job was sent on it) or an
  epic (it has subcards); nil for any other card, which has no cost to
  show (the card panel's lead-time line, #1954).
  """
  def worked_brief(%Card{id: id} = card, opts \\ []) do
    worked? =
      Repo.exists?(from j in Job, where: j.card_id == ^id) or
        Repo.exists?(from b in Board, where: b.parent_card_id == ^id)

    if worked?, do: brief(card, opts)
  end

  ## Cost ------------------------------------------------------------------------

  # What the jobs spent, in total and by the phase of each one's run.
  defp cost(jobs, rejected_at) do
    by_job = for job <- jobs, c = JobCost.of(job), do: {cost_phase(job, rejected_at), c}

    phases =
      by_job
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
      |> Map.new(fn {phase, costs} -> {phase, JobCost.sum(costs)} end)

    case JobCost.sum(Enum.map(by_job, &elem(&1, 1))) do
      nil -> nil
      total -> %{total: total, phases: phases}
    end
  end

  defp cost_phase(%Job{kind: "verify"}, _rejected_at), do: :verify

  defp cost_phase(%Job{} = job, rejected_at) do
    cond do
      job.kind == Verified.merge_kind() -> :merge
      job.claimed_at && rework?(job.claimed_at, rejected_at) -> :rework
      true -> :build
    end
  end

  # Several cards' costs as one: totals added, phases added phase by phase.
  defp sum_costs(costs) do
    case Enum.reject(costs, &is_nil/1) do
      [] ->
        nil

      known ->
        phases =
          known
          |> Enum.flat_map(&Map.to_list(&1.phases))
          |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
          |> Map.new(fn {phase, cs} -> {phase, JobCost.sum(cs)} end)

        %{total: JobCost.sum(Enum.map(known, & &1.total)), phases: phases}
    end
  end

  ## What the record holds ------------------------------------------------------

  defp jobs(card) do
    from(j in Job, where: j.card_id == ^card.id, order_by: [asc: j.inserted_at, asc: j.id])
    |> Repo.all()
  end

  defp comments(card) do
    from(c in Comment,
      where: c.card_id == ^card.id and (is_nil(c.kind) or c.kind != "epic_log"),
      order_by: [asc: c.inserted_at, asc: c.id]
    )
    |> Repo.all()
  end

  defp subcards(card) do
    case Repo.preload(card, [sub_board: [cards: :column]], force: true).sub_board do
      nil -> []
      %Board{cards: cards} -> Enum.sort_by(cards, &{&1.column && &1.column.position, &1.position})
    end
  end

  # When the card was finished: its merge where a merge job did it, else
  # its completion. Nil while it is open.
  defp done_at(%Card{completed: true} = card, jobs) do
    merged =
      jobs
      |> Enum.filter(&(&1.kind == Verified.merge_kind() and &1.status == "done"))
      |> Enum.map(&sec(&1.finished_at))
      |> Enum.reject(&is_nil/1)
      |> Enum.max(DateTime, fn -> nil end)

    merged || sec(card.completed_at)
  end

  defp done_at(_card, _jobs), do: nil

  # The first succeeded deploy naming the card, on a board that records them.
  defp deployed_at(_card, nil), do: nil

  defp deployed_at(card, done_at) do
    from(d in Deployment,
      join: b in Board,
      on: b.id == d.board_id,
      where:
        b.delivery_metrics and d.status == "succeeded" and
          fragment("? @> ?", d.card_ids, type(^[card.id], {:array, :integer})),
      select: coalesce(d.finished_at, d.started_at)
    )
    |> Repo.all()
    |> Enum.map(&sec/1)
    |> Enum.filter(&(DateTime.compare(&1, done_at) != :lt))
    |> Enum.min(DateTime, fn -> nil end)
  end

  defp ends(deployed, _done) when not is_nil(deployed), do: :deployed
  defp ends(_deployed, done) when not is_nil(done), do: :completed
  defp ends(_deployed, _done), do: :open

  defp rejected_at(comments) do
    Enum.find_value(comments, fn c ->
      if String.starts_with?(c.body || "", "**Rejected** by"), do: sec(c.inserted_at)
    end)
  end

  ## Intervals: what each recorded thing claims ---------------------------------

  defp interval(phase, from, to, note, refs),
    do: %{phase: phase, from: sec(from), to: sec(to), note: note, refs: refs}

  defp job_intervals(jobs, rejected_at, now) do
    Enum.flat_map(jobs, fn job ->
      ref = "job ##{job.id}"
      ended = job.finished_at || if(Job.open?(job), do: now, else: job.updated_at)
      claimed = job.claimed_at || if(job.status == "queued", do: now, else: ended)
      job_kind(job, ref, job.inserted_at, claimed, ended, rejected_at)
    end)
  end

  defp job_kind(%Job{kind: "verify", audit: true}, _ref, _queued, _claimed, _ended, _rej), do: []

  defp job_kind(%Job{kind: "verify"} = job, ref, queued, claimed, ended, _rej) do
    [
      interval(:verification_wait, queued, claimed, "verify job queued", [ref]),
      interval(:verify, claimed, ended, "verify job #{job.status}", [ref])
    ]
  end

  defp job_kind(%Job{} = job, ref, queued, claimed, ended, rejected_at) do
    if job.kind == Verified.merge_kind() do
      [interval(:merge, queued, ended, "merge job #{job.status}", [ref])]
    else
      run = if rework?(claimed, rejected_at), do: :rework, else: :build
      note = if run == :rework, do: "after a rejection", else: nil

      [
        interval(:waiting_for_runner, queued, claimed, "job queued", [ref]),
        interval(run, claimed, ended, note, [ref])
      ]
    end
  end

  defp rework?(_claimed, nil), do: false
  defp rework?(claimed, rejected_at), do: DateTime.compare(sec(claimed), rejected_at) != :lt

  defp wait_intervals(waits) do
    Enum.map(waits, fn w ->
      interval(:waiting_on_person, w.from, w.to, "waiting on #{w.on}", ["wait ##{w.id}"])
    end)
  end

  defp deploy_interval(nil, _deployed), do: []
  defp deploy_interval(_done, nil), do: []

  defp deploy_interval(done, deployed),
    do: [interval(:deploy, done, deployed, "done, not yet deployed", [])]

  # The lists it sat in: the ready list is waiting for a runner, a doing
  # list is building only on a card no job was ever sent on (a person's
  # work), other open lists are the backlog. Done and dropped lists claim
  # nothing.
  defp stay_intervals(stays, jobs, parent_jobs) do
    worked? = Enum.any?(jobs, &work?/1)
    roles = list_roles(stays)

    Enum.flat_map(stays, fn stay ->
      stay_phase(stay, roles[{stay.board_id, stay.list}], worked?, parent_jobs)
    end)
  end

  defp stay_phase(%{category: cat}, _role, _worked?, _parents)
       when cat in ~w(done dropped archived),
       do: []

  defp stay_phase(_stay, :done, _worked?, _parents), do: []

  defp stay_phase(stay, :ready, _worked?, _parents),
    do: [interval(:waiting_for_runner, stay.from, stay.to, "in the ready list #{stay.list}", [])]

  # Its own jobs claim the time they ran; the rest of a doing list is
  # unexplained.
  defp stay_phase(_stay, :doing, true, _parents), do: []

  # A person's work, on a card no job was ever sent on or above.
  defp stay_phase(stay, :doing, false, []),
    do: [
      interval(:build, stay.from, stay.to, "in #{stay.list}, no runner job: worked by hand", [])
    ]

  # A subcard: built by the epic's job (or jobs) running while it sat here.
  defp stay_phase(stay, :doing, false, parents) do
    Enum.flat_map(parents, fn job ->
      from = later(stay.from, sec(job.claimed_at))
      to = earlier(stay.to, sec(job.finished_at) || stay.to)

      if from && DateTime.compare(from, to) == :lt,
        do: [
          interval(:build, from, to, "in #{stay.list}, built in its epic's job", [
            "job ##{job.id}"
          ])
        ],
        else: []
    end)
  end

  defp stay_phase(stay, _role, _worked?, _parents),
    do: [interval(:backlog, stay.from, stay.to, "in #{stay.list}", [])]

  defp later(_a, nil), do: nil
  defp later(a, b), do: if(DateTime.compare(a, b) == :lt, do: b, else: a)
  defp earlier(a, b), do: if(DateTime.compare(a, b) == :gt, do: b, else: a)

  # The cards above `card`: its epic, the epic's epic, and so on.
  defp ancestor_ids(%Card{board_id: board_id}), do: ancestor_ids(board_id, [])

  defp ancestor_ids(board_id, acc) do
    case Repo.one(
           from b in Board,
             join: c in Card,
             on: c.id == b.parent_card_id,
             where: b.id == ^board_id,
             select: {c.id, c.board_id}
         ) do
      {card_id, parent_board} when length(acc) < 10 -> ancestor_ids(parent_board, [card_id | acc])
      _ -> acc
    end
  end

  defp work_jobs_on([]), do: []

  defp work_jobs_on(card_ids) do
    from(j in Job,
      where: j.card_id in ^card_ids and not is_nil(j.claimed_at),
      order_by: [asc: j.claimed_at, asc: j.id]
    )
    |> Repo.all()
    |> Enum.filter(&work?/1)
  end

  # {board id, list name} => :ready, :doing, :done or nil, as the guide
  # reads the boards it sat on (a Simple board's lists have no category).
  defp list_roles(stays) do
    stays
    |> Enum.map(& &1.board_id)
    |> Enum.uniq()
    |> Enum.reject(&is_nil/1)
    |> Enum.flat_map(fn board_id ->
      columns = Repo.all(from c in Column, where: c.board_id == ^board_id)
      ready = APIGuide.list_roles(columns).ready

      Enum.map(columns, &{{board_id, &1.name}, list_role(columns, &1, ready)})
    end)
    |> Map.new()
  end

  defp list_role(_columns, %Column{id: id}, %Column{id: id}), do: :ready

  defp list_role(columns, col, _ready) do
    case APIGuide.role(columns, col) do
      "doing" -> :doing
      role when role in ["done", "dropped"] -> :done
      _ -> nil
    end
  end

  defp work?(%Job{kind: kind}), do: not Enum.member?(["verify", Verified.merge_kind()], kind)

  ## CI ----------------------------------------------------------------------

  # Build events in time order, from the comments the loop writes and the
  # steps a job kept, folded into spans.
  defp ci_intervals(comments, jobs, to) do
    events =
      (Enum.flat_map(comments, &comment_events/1) ++ Enum.flat_map(jobs, &step_events/1))
      |> Enum.sort_by(& &1.at, DateTime)

    {spans, open} = Enum.reduce(events, {[], nil}, &fold_event/2)

    spans =
      case open do
        nil -> spans
        open -> [close_open(open, jobs, to) | spans]
      end

    Enum.reverse(spans)
  end

  defp comment_events(%Comment{} = c) do
    kinds = Regex.scan(@build_event, c.body || "", capture: :all_but_first)
    kinds = Enum.map(kinds, fn [k] -> String.downcase(k) end)
    fixed_before_report = fixed_before_report?(kinds)

    Enum.map(kinds, fn k ->
      %{
        at: sec(c.inserted_at),
        kind: k,
        ref: "comment ##{c.id}",
        fixed: k == "failed" and fixed_before_report
      }
    end)
  end

  # "Build failed" followed by "Build started" in the same comment: the fix
  # was pushed before the failure was reported.
  defp fixed_before_report?(kinds) do
    kinds
    |> Enum.drop_while(&(&1 != "failed"))
    |> Enum.member?("started")
  end

  defp step_events(%Job{steps: steps, id: id}) when is_list(steps) do
    Enum.flat_map(steps, fn step ->
      with text when is_binary(text) <- step["text"],
           {:ok, at, _} <- DateTime.from_iso8601(step["at"] || ""),
           kind when is_binary(kind) <- step_kind(text) do
        [%{at: sec(at), kind: kind, ref: "job ##{id}", fixed: false}]
      else
        _ -> []
      end
    end)
  end

  defp step_events(_job), do: []

  defp step_kind(text) do
    cond do
      not Regex.match?(~r/\b(CI|checks?)\b/i, text) -> nil
      Regex.match?(~r/\b(fail\w*|red)\b/i, text) -> "failed"
      Regex.match?(~r/\b(green|pass\w*)\b/i, text) -> "passed"
      true -> "started"
    end
  end

  defp fold_event(%{kind: "started"} = e, {spans, nil}), do: {spans, e}
  defp fold_event(%{kind: "started"}, {spans, open}), do: {spans, open}
  defp fold_event(_e, {spans, nil}), do: {spans, nil}

  defp fold_event(e, {spans, open}) do
    result = if e.kind == "failed", do: "red", else: "green"

    note =
      if e.fixed,
        do:
          "CI, red; the failure was reported with its fix already pushed (#{e.ref}), so " <>
            "this span includes the fix: the record doesn't say when the run itself ended",
        else: "CI, #{result}"

    {[interval(:ci, open.at, e.at, note, Enum.uniq([open.ref, e.ref])) | spans], nil}
  end

  # A run nothing reported the end of: up to the end of the job it ran in.
  defp close_open(open, jobs, to) do
    ended =
      jobs
      |> Enum.filter(&(work?(&1) and &1.finished_at))
      |> Enum.map(&sec(&1.finished_at))
      |> Enum.find(to, &(DateTime.compare(&1, open.at) == :gt))

    interval(:ci, open.at, ended, "CI, no result recorded", [open.ref])
  end

  ## The sweep -----------------------------------------------------------------

  defp sweep(_intervals, from, to) when from == to, do: []

  defp sweep(intervals, from, to) do
    intervals = Enum.filter(intervals, &(DateTime.compare(&1.from, &1.to) == :lt))

    cuts =
      intervals
      |> Enum.flat_map(&[&1.from, &1.to])
      |> Enum.filter(&inside?(&1, from, to))
      |> Enum.concat([from, to])
      |> Enum.uniq_by(&DateTime.to_unix/1)
      |> Enum.sort(DateTime)

    cuts
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.map(fn [a, b] -> piece(intervals, a, b) end)
    |> merge_pieces()
  end

  defp inside?(t, from, to),
    do: DateTime.compare(t, from) == :gt and DateTime.compare(t, to) == :lt

  defp piece(intervals, a, b) do
    winner =
      intervals
      |> Enum.filter(&(DateTime.compare(&1.from, a) != :gt and DateTime.compare(&1.to, b) != :lt))
      |> Enum.min_by(&@rank[&1.phase], fn -> nil end)

    case winner do
      nil -> %{phase: :unexplained, from: a, to: b, note: nil, refs: []}
      w -> %{w | from: a, to: b}
    end
  end

  defp merge_pieces(pieces) do
    pieces
    |> Enum.reduce([], fn
      p, [last | rest]
      when last.phase == p.phase and last.note == p.note and last.refs == p.refs ->
        [%{last | to: p.to} | rest]

      p, acc ->
        [p | acc]
    end)
    |> Enum.reverse()
    |> Enum.map(&Map.put(&1, :seconds, DateTime.diff(&1.to, &1.from)))
  end

  defp totals(segments) do
    Enum.reduce(segments, Map.new(@phases, &{&1, 0}), fn s, acc ->
      Map.update!(acc, s.phase, &(&1 + s.seconds))
    end)
  end

  ## Which jobs held the pool ---------------------------------------------------

  # On a wait for a runner, the other jobs on the same board's tree and the
  # same pool that were running meanwhile.
  defp held_by(%{phase: :waiting_for_runner} = seg, card, jobs) do
    pools = jobs |> Enum.filter(&work?/1) |> Enum.map(& &1.pool) |> Enum.uniq()
    root = Boards.root_of_board(card.board_id)

    others =
      from(j in Job,
        where:
          j.root_board_id == ^root and j.card_id != ^card.id and j.pool in ^pools and
            not is_nil(j.claimed_at) and j.claimed_at < ^seg.to and
            (is_nil(j.finished_at) or j.finished_at > ^seg.from),
        order_by: [asc: j.claimed_at, asc: j.id],
        preload: :card
      )
      |> Repo.all()
      |> Enum.map(
        &%{
          job_id: &1.id,
          card_id: &1.card_id,
          title: &1.card && &1.card.title,
          kind: &1.kind,
          from: sec(&1.claimed_at),
          to: &1.finished_at && sec(&1.finished_at)
        }
      )

    Map.put(seg, :held_by, others)
  end

  defp held_by(seg, _card, _jobs), do: seg

  defp sec(nil), do: nil
  defp sec(%DateTime{} = at), do: DateTime.truncate(at, :second)
  defp sec(%NaiveDateTime{} = at), do: at |> DateTime.from_naive!("Etc/UTC") |> sec()
end
