defmodule Slipdock.CardState do
  @moduledoc """
  What is happening to a card, worked out from what is already recorded
  about it (#1117, KTD13), and put on it as its virtual `state`:

    * `line` — one line saying what is going on, or nil when there is
      nothing to say. The first that applies: an open wait ("Waiting on
      Dana · 41m"), a queued job held back ("Held · paused by David: bad
      deploy"), a queued job ("Queued · dev · 3m"), a job being worked
      ("Running · runner-2 · 7m"), the newest job failing ("Failed ·
      runner-2 · 2h ago"). With an open handoff, its next step follows
      (" · Next: …"). A card with no job and no wait has no line, so a board
      that never uses either looks as it always has;
    * `kind` — which of those the line is, for the tile's colour:
      "waiting", "held", "queued", "claimed", "running", "failed" or
      "timeout" (#1132); nil with no line;
    * `held` — the held reason of a queued job (`Slipdock.Runners.held_reason/1`);
    * `loop` — the runner loop holding the card (#2027): `%{runner: name,
      kind: "build" | "verify" | "merge", job_id: id}` while its job is
      claimed or running, else nil. It shows beside the card's assignees but
      is not one: assignees stay people, and every assignee filter, the Work
      page and the rules' `unassigned` trigger ignore it. It goes when the job
      ends, however it ends (done, parked, failed, cancelled, timed out or
      requeued), since it is read off the job and nothing is stored. A
      subcard with no open job of its own that its epic's job is working
      (#2899: the job's current step names it, `epic_jobs/1`) shows that
      job as its loop, and its line reads as the job's with " · in #<epic>";
    * `driver` — "agent" while a runner's job holds the card, else the kind
      of whoever last put it in a list ("agent" or "human"), else nil. Only
      worked out on a tree with a runner rule, or for a card that has had a
      job: anywhere else nobody needs telling a person moved it;
    * `in_list_since` and `age` — when the card came into its list and the
      seconds since, from the movement ledger. A card whose latest ledger row
      put it in another list (a move the backfill could not read) has an
      unknown time there: its age counts from that row, and `known` is false;
    * `usual`, `over_usual` and `stuck` — the list's usual stay
      (`Slipdock.Pulse.usual_stays/1`), and by how much the card is past it.
      Never on a done, dropped or Scheduled list, a completed card, a card with an open
      wait (the person is the hold-up, not the card), an epic with open
      subcards (its stay is its subcards', #2131), or an unknown age.

    * `verifier` — whether the card's board queues a verify job for a
      verifier agent when a card is submitted (`verify_work` with a
      `verify_pool`), so a pending card's `review` flag clears without a
      person (`Slipdock.Attention`, #2624).

  `put/3` decorates a batch of cards with a fixed number of queries,
  whatever their number: the board page, `Boards.Cards.list_cards/2` and
  `Boards.Cards.get_card/1` go through it, and the tile, `API.JSON.card/1`, MCP
  `card_line/1` and the CLI all read the same values.
  """

  import Ecto.Query

  alias Slipdock.Boards.{Board, Card, CardMove, Column, Wait}
  alias Slipdock.Runners.Job
  alias Slipdock.{Pulse, Repo, Runners}

  defstruct line: nil,
            kind: nil,
            held: nil,
            loop: nil,
            driver: nil,
            in_list_since: nil,
            age: nil,
            known: false,
            usual: nil,
            over_usual: nil,
            stuck: false,
            verifier: false

  # A Scheduled list's cards (#2100) wait there for their feed by design:
  # no "over usual" for them.
  @quiet ~w(done dropped scheduled)

  @doc "The drivers a filter takes: everything, agent-held or person-held."
  def drivers, do: ~w(all agent human)

  @doc """
  `cards` (all on `board`), each with its `state` set. Options:

    * `:usual` — the board's usual stays, when already worked out (the board
      page has them); otherwise they are;
    * `:columns` — the board's lists, when the cards don't carry theirs;
    * `:runner_tree` — `runner_tree?/1` for the board's tree, when known;
    * `:now` — the clock, for tests.
  """
  def put(cards, board, opts \\ [])
  def put([], _board, _opts), do: []

  def put(cards, %Board{} = board, opts) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    ids = Enum.map(cards, & &1.id)
    jobs = jobs(ids)

    ctx = %{
      now: now,
      jobs: jobs,
      epic_jobs: ids |> Enum.reject(&open?(jobs[&1])) |> epic_jobs(),
      held: held(jobs),
      entries: entries(ids),
      epics: open_epics(ids),
      usual: Keyword.get_lazy(opts, :usual, fn -> Pulse.usual_stays(board, now: now) end),
      columns: Map.new(opts[:columns] || [], &{&1.id, &1}),
      runner_tree:
        Keyword.get_lazy(opts, :runner_tree, fn -> runner_tree?(Board.root_id(board)) end),
      verifier: verifier?(board)
    }

    Enum.map(cards, &%{&1 | state: derive(&1, ctx)})
  end

  # Each card's open job if it has one (one being worked before one queued),
  # else its newest.
  defp jobs(ids) do
    from(j in Job,
      where: j.card_id in ^ids,
      distinct: j.card_id,
      order_by: [
        asc: j.card_id,
        desc:
          fragment(
            "CASE ? WHEN 'running' THEN 3 WHEN 'claimed' THEN 2 WHEN 'queued' THEN 1 ELSE 0 END",
            j.status
          ),
        desc: j.id
      ]
    )
    |> Repo.all()
    |> Map.new(&{&1.card_id, &1})
  end

  # Only queued jobs can be held; asked once for all of them.
  defp held(jobs), do: jobs |> Map.values() |> Runners.held_reasons()

  # Each card's latest ledger row putting it in a list.
  defp entries(ids) do
    from(m in CardMove,
      where: m.card_id in ^ids and m.kind in ^CardMove.entry_kinds(),
      distinct: m.card_id,
      order_by: [asc: m.card_id, desc: m.inserted_at, desc: m.id],
      select: map(m, [:card_id, :to_column_id, :inserted_at, :actor_kind])
    )
    |> Repo.all()
    |> Map.new(&{&1.card_id, &1})
  end

  # The cards among `ids` whose sub-board still holds an open card (#2131):
  # an epic in progress sits there for as long as its subcards take, so its
  # list's usual stay, worked out from single cards, says nothing about it.
  defp open_epics(ids) do
    from(c in Card,
      join: b in Board,
      on: b.id == c.board_id,
      where:
        b.parent_card_id in ^ids and is_nil(b.archived_at) and is_nil(c.archived_at) and
          not c.completed,
      distinct: true,
      select: b.parent_card_id
    )
    |> Repo.all()
    |> MapSet.new()
  end

  @doc "Whether any board in the tree under `root_id` has a rule that sends cards to a runner."
  def runner_tree?(root_id) do
    from(r in Slipdock.Automations.Rule,
      join: b in Board,
      on: b.id == r.board_id,
      where: b.id == ^root_id or b.root_id == ^root_id,
      select: r.spec
    )
    |> Repo.all()
    |> Enum.any?(fn spec ->
      Enum.any?(Slipdock.Automations.Spec.actions(spec), &(&1["type"] == "runner"))
    end)
  end

  defp derive(%Card{} = card, ctx) do
    wait = Card.open_wait(card)
    {job, via} = card_job(card, ctx)
    held = job && ctx.held[job.id]
    entry = ctx.entries[card.id]

    {since, known} =
      case entry do
        %{to_column_id: id, inserted_at: at} when id == card.column_id -> {at, true}
        %{inserted_at: at} -> {at, false}
        nil -> {nil, false}
      end

    age = since && max(DateTime.diff(ctx.now, since), 0)
    usual = if known, do: ctx.usual[card.column_id]
    over = over_usual(card, ctx, wait, usual, age)
    {kind, line} = line(card, wait, job, held, via, ctx.now)

    %__MODULE__{
      line: line,
      kind: kind,
      held: held,
      loop: job_loop(job),
      driver: if(ctx.runner_tree or job, do: driver(job, entry)),
      in_list_since: since,
      age: age,
      known: known,
      usual: usual,
      over_usual: over,
      stuck: not is_nil(over),
      verifier: ctx.verifier
    }
  end

  # The job to read the card's state off, and the epic it is on when it is
  # the job of an epic above the card working it (#2899): the card's own
  # open job first (`put/3` asks for an epic's only for cards without one),
  # then such an epic's, then the card's newest. `epic_jobs/1` never gives
  # one for a completed card.
  defp card_job(card, ctx) do
    case ctx.epic_jobs[card.id] do
      %Job{} = epic -> {epic, epic}
      nil -> {ctx.jobs[card.id], nil}
    end
  end

  defp open?(%Job{status: status}), do: Enum.member?(Job.open_statuses(), status)
  defp open?(_job), do: false

  @doc """
  The jobs of epics that are working some of `card_ids` (#2899), by card
  id: a build job claimed or running on a card above the card (its epic,
  or one further up), whose current step names it (`#2835 CI running`).
  An epic's job works its subcards inside itself, so without this a
  subcard it is building has no job and reads as nobody on it. Only open
  (not completed, not archived) cards are keys; with two such jobs, the
  running one, then the newest. One query for the jobs, and one more per
  level climbed only when a step names one of `card_ids`.
  """
  def epic_jobs([]), do: %{}

  def epic_jobs(card_ids) do
    wanted = MapSet.new(card_ids)
    not_builds = [Slipdock.Overseer.kind() | Slipdock.Verified.finishing_kinds()]

    named =
      from(j in Job,
        where: j.status in ~w(claimed running) and not is_nil(j.card_id),
        where: not is_nil(j.step) and j.kind not in ^not_builds
      )
      |> Repo.all()
      |> Enum.flat_map(fn job ->
        for id <- step_card_ids(job.step),
            id != job.card_id,
            MapSet.member?(wanted, id),
            do: {id, job}
      end)

    case named do
      [] ->
        %{}

      _ ->
        above = named |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> ancestors()

        named
        |> Enum.filter(fn {id, job} -> Enum.member?(Map.get(above, id, []), job.card_id) end)
        |> Enum.sort_by(fn {_id, job} -> {job.status == "running", job.id} end)
        |> Map.new()
    end
  end

  @doc "The card ids a job's step names, in order: `#2835 CI running` → `[2835]`."
  def step_card_ids(step) when is_binary(step) do
    ~r/(?<![\w&#])#([0-9]+)\b/u
    |> Regex.scan(step, capture: :all_but_first)
    |> Enum.map(fn [id] -> String.to_integer(id) end)
    |> Enum.uniq()
  end

  def step_card_ids(_step), do: []

  # Each open card among `ids`, with the cards above it (its epic, the
  # epic's epic, …), nearest first.
  defp ancestors(ids) do
    open =
      from(c in Card,
        where: c.id in ^ids and not c.completed and is_nil(c.archived_at),
        select: c.id
      )
      |> Repo.all()

    climb(Map.new(open, &{&1, &1}), Map.new(open, &{&1, []}), 0)
  end

  # `frontier` maps each card to the card reached so far above it.
  @max_depth 10
  defp climb(frontier, acc, depth) when map_size(frontier) == 0 or depth >= @max_depth,
    do: Map.new(acc, fn {id, above} -> {id, Enum.reverse(above)} end)

  defp climb(frontier, acc, depth) do
    reached = frontier |> Map.values() |> Enum.uniq()

    parents =
      from(c in Card,
        join: b in Board,
        on: b.id == c.board_id,
        where: c.id in ^reached and not is_nil(b.parent_card_id),
        select: {c.id, b.parent_card_id}
      )
      |> Repo.all()
      |> Map.new()

    next =
      Enum.flat_map(frontier, fn {id, at} ->
        case parents[at] do
          nil -> []
          parent -> [{id, parent}]
        end
      end)
      |> Map.new()

    acc = Enum.reduce(next, acc, fn {id, parent}, acc -> Map.update!(acc, id, &[parent | &1]) end)
    climb(next, acc, depth + 1)
  end

  @doc "Whether `board` sends a submitted card to a verifier agent (a verify pool, with verified work on)."
  def verifier?(%Board{verify_work: true, verify_pool: pool}) when is_binary(pool) and pool != "",
    do: true

  def verifier?(_board), do: false

  # By how much the card is past its list's usual stay, or nil: see the
  # moduledoc for the cards that are never over it.
  defp over_usual(_card, _ctx, _wait, nil, _age), do: nil

  defp over_usual(card, ctx, wait, usual, age) do
    if is_nil(wait) && not card.completed && not quiet?(column(card, ctx)) &&
         not MapSet.member?(ctx.epics, card.id) && age > usual,
       do: age - usual
  end

  defp column(%Card{column: %Column{} = col}, _ctx), do: col
  defp column(%Card{column_id: id}, ctx), do: ctx.columns[id]

  defp quiet?(%Column{category: category}), do: Enum.member?(@quiet, category)
  defp quiet?(_), do: false

  defp job_loop(%Job{status: status} = job) when status in ~w(claimed running),
    do: %{runner: job.runner_name, kind: loop_kind(job.kind), job_id: job.id}

  defp job_loop(_job), do: nil

  # A job's kind is what its runner runs (`claude`, `codex`, a name of the
  # runner's own): only verify and merge jobs are told apart, and every
  # other kind builds.
  defp loop_kind(kind) when kind in ~w(verify merge), do: kind
  defp loop_kind(_kind), do: "build"

  @doc """
  The runner loop holding a card while its job is claimed or running
  (`%{runner:, kind:, job_id:}`), or nil: nil too for a card nobody worked
  a state out for.
  """
  def loop(%{state: %__MODULE__{loop: loop}}), do: loop
  def loop(_card), do: nil

  @doc """
  The loop holding a card, from its jobs (any order): its running job's,
  else its claimed one's, as `put/3` picks; nil with neither. For a card
  read with its jobs rather than its state (the card panel).
  """
  def loop_of(jobs) do
    jobs
    |> Enum.filter(&Enum.member?(~w(claimed running), &1.status))
    |> Enum.sort_by(&{&1.status == "running", &1.id}, :desc)
    |> List.first()
    |> job_loop()
  end

  @doc """
  The loop holding one card read with its jobs: `loop_of/1` of them, else
  the loop of an epic's job working it (#2899, `epic_jobs/1`).
  """
  def loop_of(%Card{id: id, completed: completed}, jobs) do
    loop_of(jobs) || if(not completed, do: job_loop(epic_jobs([id])[id]))
  end

  @doc """
  The loops holding some cards, by card id: only the cards a claimed or
  running job holds are keys, their own or an epic's working them (#2899,
  `epic_jobs/1`). For cards read light, without a state (the outline's,
  from `Slipdock.Boards.Rollup`).
  """
  def loops([]), do: %{}

  def loops(card_ids) do
    own =
      from(j in Job, where: j.card_id in ^card_ids and j.status in ~w(claimed running))
      |> Repo.all()
      |> Enum.group_by(& &1.card_id)
      |> Map.new(fn {card_id, jobs} -> {card_id, loop_of(jobs)} end)

    card_ids
    |> Enum.reject(&Map.has_key?(own, &1))
    |> epic_jobs()
    |> Map.new(fn {card_id, job} -> {card_id, job_loop(job)} end)
    |> Map.merge(own)
  end

  @doc "The loop as its chip reads: \"Mac Studio · verify\"."
  def loop_label(%{runner: runner, kind: kind}),
    do: join([runner || "a runner", kind])

  defp driver(%Job{status: status}, _entry) when status in ~w(claimed running), do: "agent"
  defp driver(_job, %{actor_kind: kind}) when kind in ~w(agent human), do: kind
  defp driver(_job, _entry), do: nil

  # `{kind, line}`, or `{nil, nil}` when there is nothing to say.
  defp line(card, wait, job, held, via, now) do
    case base(card, wait, job, held, now) do
      nil ->
        {nil, nil}

      {kind, line} ->
        line = if via && kind != "waiting", do: line <> " · in ##{via.card_id}", else: line

        case Card.open_handoff(card) do
          nil -> {kind, line}
          handoff -> {kind, line <> " · Next: " <> handoff.next_step}
        end
    end
  end

  defp base(_card, %Wait{} = wait, _job, _held, now),
    do: {"waiting", "Waiting on #{Wait.on_name(wait)} · #{since(wait.inserted_at, now)}"}

  defp base(_card, nil, %Job{status: "queued"}, held, _now) when is_binary(held),
    do: {"held", "Held · " <> held}

  defp base(_card, nil, %Job{status: "queued"} = job, nil, now),
    do: {"queued", join(["Queued", job.pool, since(job.inserted_at, now)])}

  defp base(_card, nil, %Job{status: "claimed"} = job, _held, now),
    do:
      {"claimed",
       join(["Claimed", job.runner_name, since(job.claimed_at || job.updated_at, now)])}

  defp base(_card, nil, %Job{status: "running"} = job, _held, now),
    do:
      {"running",
       join(["Running", job.runner_name, since(job.started_at || job.claimed_at, now)])}

  defp base(%Card{completed: false}, nil, %Job{status: status} = job, _held, now)
       when status in ~w(failed timeout),
       do:
         {status,
          join([
            if(status == "failed", do: "Failed", else: "Timed out"),
            job.runner_name,
            since(job.finished_at || job.updated_at, now) <> " ago"
          ])}

  defp base(_card, _wait, _job, _held, _now), do: nil

  defp join(parts), do: parts |> Enum.reject(&Enum.member?([nil, ""], &1)) |> Enum.join(" · ")

  defp since(nil, _now), do: nil
  defp since(at, now), do: Pulse.duration(max(DateTime.diff(now, at), 0))

  @doc """
  The age chip's words: "3h", or "3h · 1h over usual" when the card is past
  its list's usual stay. Nil when its time in the list isn't known at all.
  """
  def age_text(%__MODULE__{age: nil}), do: nil

  def age_text(%__MODULE__{age: age, over_usual: nil}), do: Pulse.duration(age)

  def age_text(%__MODULE__{age: age, over_usual: over}),
    do: "#{Pulse.duration(age)} · #{Pulse.duration(over)} over usual"

  def age_text(_), do: nil

  @doc """
  The state as an API answers it: only what there is to say, so a card on
  a board that uses none of this carries just its age.
  """
  def to_map(%__MODULE__{} = s) do
    [
      state: s.line,
      held: s.held,
      loop: s.loop,
      driver: s.driver,
      in_list_since: if(s.known, do: s.in_list_since),
      age: s.age,
      usual_stay: s.usual,
      over_usual: s.over_usual,
      stuck: if(s.stuck, do: true)
    ]
    |> Enum.reject(fn {_, v} -> is_nil(v) end)
    |> Map.new()
  end

  def to_map(_), do: %{}

  @doc """
  Whether a card passes the `stuck` and `driver` filters. A card nobody
  worked a state out for passes neither when one is set.
  """
  def matches?(card, stuck, driver) do
    state = Map.get(card, :state)

    (stuck != true or match?(%__MODULE__{stuck: true}, state)) and
      (Enum.member?([nil, "", "all"], driver) or match?(%__MODULE__{driver: ^driver}, state))
  end
end
