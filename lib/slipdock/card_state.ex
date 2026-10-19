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
      Never on a done or dropped list, a completed card, a card with an open
      wait (the person is the hold-up, not the card), or an unknown age.

  `put/3` decorates a batch of cards with a fixed number of queries,
  whatever their number: the board page, `Boards.list_cards/2` and
  `Boards.get_card/1` go through it, and the tile, `API.JSON.card/1`, MCP
  `card_line/1` and the CLI all read the same values.
  """

  import Ecto.Query

  alias Slipdock.Boards.{Board, Card, CardMove, Column, Wait}
  alias Slipdock.Runners.Job
  alias Slipdock.{Pulse, Repo, Runners}

  defstruct line: nil,
            kind: nil,
            held: nil,
            driver: nil,
            in_list_since: nil,
            age: nil,
            known: false,
            usual: nil,
            over_usual: nil,
            stuck: false

  @quiet ~w(done dropped)

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
      held: held(jobs),
      entries: entries(ids),
      usual: Keyword.get_lazy(opts, :usual, fn -> Pulse.usual_stays(board, now: now) end),
      columns: Map.new(opts[:columns] || [], &{&1.id, &1}),
      runner_tree:
        Keyword.get_lazy(opts, :runner_tree, fn -> runner_tree?(Board.root_id(board)) end)
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
    job = ctx.jobs[card.id]
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

    over =
      if usual && is_nil(wait) && not card.completed && not quiet?(column(card, ctx)) &&
           age > usual,
         do: age - usual

    {kind, line} = line(card, wait, job, held, ctx.now)

    %__MODULE__{
      line: line,
      kind: kind,
      held: held,
      driver: if(ctx.runner_tree or job, do: driver(job, entry)),
      in_list_since: since,
      age: age,
      known: known,
      usual: usual,
      over_usual: over,
      stuck: not is_nil(over)
    }
  end

  defp column(%Card{column: %Column{} = col}, _ctx), do: col
  defp column(%Card{column_id: id}, ctx), do: ctx.columns[id]

  defp quiet?(%Column{category: category}), do: category in @quiet
  defp quiet?(_), do: false

  defp driver(%Job{status: status}, _entry) when status in ~w(claimed running), do: "agent"
  defp driver(_job, %{actor_kind: kind}) when kind in ~w(agent human), do: kind
  defp driver(_job, _entry), do: nil

  # `{kind, line}`, or `{nil, nil}` when there is nothing to say.
  defp line(card, wait, job, held, now) do
    case base(card, wait, job, held, now) do
      nil ->
        {nil, nil}

      {kind, line} ->
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

  defp join(parts), do: parts |> Enum.reject(&(&1 in [nil, ""])) |> Enum.join(" · ")

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
      (driver in [nil, "", "all"] or match?(%__MODULE__{driver: ^driver}, state))
  end
end
