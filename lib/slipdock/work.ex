defmodule Slipdock.Work do
  @moduledoc """
  One person's work: every card assigned to them, across every board and
  every level, grouped by when it is due.

  This is what the My work page shows (`SlipdockWeb.WorkLive.Index`) and what
  the assistant's `assigned_cards` tool answers from, so the two cannot drift
  apart: the same sections, in the same order, with the same idea of what
  "overdue" means.

  Each card comes with the `path` of names above it — the root board, then
  every card the sub-boards hang from — because "Fix the retry" means nothing
  without "QVM V1 Remediation › Broker integrations" in front of it.
  """

  import Ecto.Query

  alias Slipdock.{Access, Boards, Repo}
  alias Slipdock.Accounts.User
  alias Slipdock.Boards.{Activity, Board, Card, CardMove, Column, Wait}
  alias Slipdock.Runners.Job

  @sections [
    {:overdue, "Overdue", "text-error"},
    {:today, "Due today", "text-primary"},
    {:week, "Next 7 days", nil},
    {:later, "Later", nil},
    {:none, "No due date", nil},
    {:done, "Completed", "text-success"}
  ]

  @doc "The sections, in display order, as `{key, label, tone}`."
  def sections, do: @sections

  @doc """
  Every card assigned to `user` that `viewer` may read, as
  `%{card:, path:, section:}`, due soonest first.

  `viewer` defaults to `user` — one person looking at their own work. When
  someone asks about another person's work it is the asker's permissions that
  decide what comes back, never the assignee's.

  Options: `:today` for the date the sections are reckoned from, `:board_id`
  to keep only the cards in one board's tree.
  """
  def assigned(%User{} = user, viewer \\ nil, opts \\ []) do
    viewer = viewer || user
    today = opts[:today] || Date.utc_today()

    user
    |> Boards.list_assigned_cards()
    |> then(&Access.filter_readable_cards(viewer, &1))
    |> then(fn cards ->
      case opts[:board_id] do
        nil -> cards
        id -> Enum.filter(cards, &in_tree?(&1, id))
      end
    end)
    |> Enum.map(&%{card: &1, path: path(&1), section: section(&1, today)})
  end

  @doc """
  `assigned/3` gathered into sections: `%{key, label, tone, items}`, empty
  sections left out. Pass `done: true` to include completed cards.
  """
  def grouped(%User{} = user, viewer \\ nil, opts \\ []) do
    user |> assigned(viewer, opts) |> group(opts[:done] == true)
  end

  @doc "Gathers items from `assigned/3` into sections, completed ones last."
  def group(items, done? \\ true) do
    items = if done?, do: items, else: Enum.reject(items, &(&1.section == :done))

    for {key, label, tone} <- @sections,
        in_section = Enum.filter(items, &(&1.section == key)),
        in_section != [],
        do: %{key: key, label: label, tone: tone, items: in_section}
  end

  @doc ~S'"Root › Epic › Story": the root board, then each card the sub-boards hang from.'
  def path(%Card{} = card) do
    case Boards.ancestry(card.board) do
      [] -> [card.board.name]
      [%{board: root} | _] = chain -> [root.name | Enum.map(chain, & &1.card.title)]
    end
  end

  @doc """
  Which section a card belongs in, from its effective due date — the card's
  own, or the one rolled up from its subcards.
  """
  def section(card, today \\ Date.utc_today())
  def section(%Card{completed: true}, _today), do: :done

  def section(%Card{} = card, today) do
    case Card.effective_due(card) do
      nil ->
        :none

      due ->
        case Date.diff(due, today) do
          n when n < 0 -> :overdue
          0 -> :today
          n when n <= 7 -> :week
          _ -> :later
        end
    end
  end

  ## Waiting on you

  # How long a card may sit in a doing list with nobody on it before it
  # needs an owner.
  @owner_grace 3600

  @doc """
  Everything that needs `user` (#1118, R14), oldest first: one item per card,
  `%{card:, path:, reason:, text:, since:, wait:, job:}`, where `reason` is
  the first of these that applies:

    * `"wait"` — an open wait on `user`;
    * `"wait_anyone"` — an open wait on anyone, on a card in a tree `user`
      owns or a card assigned to them (not one they asked themselves);
    * `"review"`, `"waiting"` — a card assigned to `user` flagged so
      (`waiting` only without an open wait, which says who it is on);
    * `"gave_up"` — a card the runner gave up on and flagged blocked, in a
      tree `user` owns;
    * `"failed"` — a card whose newest runner job failed or timed out, in a
      tree `user` owns, until a newer job is queued;
    * `"needs_owner"` — in a tree `user` owns, an open card in a doing list
      for over an hour with nobody on it, no open job and no open wait.

  `since` is when it started needing them: the wait's opening, the newest
  run of the flag (from the activity log), the job's end, the card's entry
  into its list. Only cards `user` may read come back; completed and
  archived ones never do, and snoozed ones only for a wait.

  Options: `:board_id` keeps one board's tree, `:roots` the trees of those
  root boards (a token's scope), `:paths` false skips working out each
  card's path (for the count), `:now` for tests.
  """
  def waiting_on_me(%User{} = user, opts \\ []) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    owned = owned_roots(user, opts[:roots])
    assigned = assigned_ids(user)

    candidates =
      waits_on(user, owned, assigned) ++
        flagged(user, now) ++ job_trouble(owned) ++ unowned(owned, now)

    cards =
      candidates
      |> Enum.map(& &1.card_id)
      |> Enum.uniq()
      |> load_cards()

    readable = user |> Access.filter_readable_cards(Map.values(cards)) |> MapSet.new(& &1.id)

    flag_since =
      flag_since(for %{reason: r, card_id: id} <- candidates, r in ~w(review waiting), do: id)

    candidates
    |> Enum.filter(&(MapSet.member?(readable, &1.card_id) and in_scope?(cards[&1.card_id], opts)))
    |> Enum.group_by(& &1.card_id)
    |> Enum.map(fn {id, found} ->
      first = Enum.min_by(found, &rank/1)
      card = cards[id]
      since = first[:since] || flag_since[{id, first.reason}] || card.inserted_at

      %{
        card: card,
        path: if(opts[:paths] == false, do: nil, else: path(card)),
        reason: first.reason,
        text: reason_text(first),
        since: DateTime.truncate(since, :second),
        wait: first[:wait],
        job: first[:job]
      }
    end)
    |> Enum.sort_by(&{&1.since, &1.card.id}, fn {a, i}, {b, j} ->
      case DateTime.compare(a, b) do
        :eq -> i <= j
        order -> order == :lt
      end
    end)
  end

  @doc "How many things are waiting on `user`: the length of `waiting_on_me/2`."
  def waiting_count(%User{} = user, opts \\ []),
    do: user |> waiting_on_me(Keyword.put(opts, :paths, false)) |> length()

  @reasons ~w(wait wait_anyone review waiting gave_up failed needs_owner)
  defp rank(%{reason: reason}), do: Enum.find_index(@reasons, &(&1 == reason))

  @doc "The reasons an item can have, in the order one card's are chosen from."
  def reasons, do: @reasons

  defp reason_text(%{reason: "wait", wait: w}), do: "Waiting on you: #{w.needs}"
  defp reason_text(%{reason: "wait_anyone", wait: w}), do: "Waiting on anyone: #{w.needs}"
  defp reason_text(%{reason: "review"}), do: "Flagged review"
  defp reason_text(%{reason: "waiting"}), do: "Flagged waiting"

  defp reason_text(%{reason: "gave_up", job: j}),
    do: "The runner gave up on it after job ##{j.id}"

  defp reason_text(%{reason: "failed", job: %{status: "timeout"} = j}),
    do: "Job ##{j.id} timed out"

  defp reason_text(%{reason: "failed", job: j}), do: "Job ##{j.id} failed"
  defp reason_text(%{reason: "needs_owner"}), do: "In progress with nobody on it"

  # The root boards `user` owns, kept to `roots` when given.
  defp owned_roots(user, roots) do
    from(b in Board, where: b.owner_id == ^user.id and is_nil(b.parent_card_id), select: b.id)
    |> then(fn q -> if roots, do: where(q, [b], b.id in ^roots), else: q end)
    |> Repo.all()
  end

  defp assigned_ids(user),
    do: from(a in "card_assignees", where: a.user_id == ^user.id, select: a.card_id)

  # Cards on a board whose tree has one of `roots` at the top.
  defp in_trees(query, roots) do
    from([c] in query,
      join: b in Board,
      on: b.id == c.board_id,
      where: b.id in ^roots or b.root_id in ^roots
    )
  end

  defp live(query),
    do: where(query, [c], is_nil(c.archived_at) and not c.completed and is_nil(c.stand_in_for_id))

  defp waits_on(user, owned, assigned) do
    anyone_cards =
      from(c in Card, select: c.id)
      |> in_trees(owned)
      |> then(&from(c in Card, where: c.id in subquery(&1) or c.id in subquery(assigned)))
      |> select([c], c.id)

    from(w in Wait,
      join: c in Card,
      on: c.id == w.card_id,
      where: is_nil(w.closed_at) and is_nil(c.archived_at) and not c.completed,
      where:
        w.on_user_id == ^user.id or
          (is_nil(w.on_user_id) and w.card_id in subquery(anyone_cards) and
             not (w.opened_by_id == ^user.id and w.kind == "human")),
      preload: [:on_user, :opened_by]
    )
    |> Repo.all()
    |> Enum.map(fn w ->
      %{
        card_id: w.card_id,
        reason: if(w.on_user_id, do: "wait", else: "wait_anyone"),
        since: w.inserted_at,
        wait: w
      }
    end)
  end

  defp flagged(user, now) do
    open_waits = from(w in Wait, where: is_nil(w.closed_at), select: w.card_id)

    from(c in Card,
      where: c.id in subquery(assigned_ids(user)),
      where: fragment("? && ?", c.flags, ^~w(review waiting)),
      select: {c.id, c.flags, c.id in subquery(open_waits)}
    )
    |> live()
    |> Slipdock.Snooze.not_snoozed(now)
    |> Repo.all()
    |> Enum.flat_map(fn {id, flags, waited?} ->
      cond do
        "review" in flags -> [%{card_id: id, reason: "review"}]
        not waited? -> [%{card_id: id, reason: "waiting"}]
        true -> []
      end
    end)
  end

  # The newest job of each card in an owned tree, when it went wrong.
  defp job_trouble([]), do: []

  defp job_trouble(owned) do
    newest =
      from(j in Job,
        where: j.root_board_id in ^owned,
        distinct: j.card_id,
        order_by: [asc: j.card_id, desc: j.id]
      )

    from(j in subquery(newest),
      join: c in Card,
      on: c.id == j.card_id,
      where: is_nil(c.archived_at) and not c.completed,
      where:
        j.status in ["failed", "timeout"] or
          (j.recovery == "gave_up" and fragment("? = ANY(?)", "blocked", c.flags)),
      select: j
    )
    |> Repo.all()
    |> Enum.map(fn j ->
      %{
        card_id: j.card_id,
        reason: if(j.recovery == "gave_up", do: "gave_up", else: "failed"),
        since: j.finished_at || j.updated_at,
        job: j
      }
    end)
  end

  # Open cards an hour or more into a doing list with nobody on them, no
  # open job and no open wait. A card whose latest ledger row is not into its
  # list (history the backfill couldn't read) has no known entry, so isn't
  # counted.
  defp unowned([], _now), do: []

  defp unowned(owned, now) do
    cutoff = DateTime.add(now, -@owner_grace, :second)

    latest =
      from(m in CardMove,
        where: m.kind in ^CardMove.entry_kinds(),
        distinct: m.card_id,
        order_by: [asc: m.card_id, desc: m.inserted_at, desc: m.id],
        select: %{card_id: m.card_id, to_column_id: m.to_column_id, at: m.inserted_at}
      )

    from(c in Card,
      join: col in Column,
      on: col.id == c.column_id and col.category == "doing",
      join: m in subquery(latest),
      on: m.card_id == c.id and m.to_column_id == c.column_id,
      where: m.at <= ^cutoff and is_nil(c.assignee_id),
      where: c.id not in subquery(from(a in "card_assignees", select: a.card_id)),
      where:
        c.id not in subquery(
          from(j in Job, where: j.status in ^Job.open_statuses(), select: j.card_id)
        ),
      where: c.id not in subquery(from(w in Wait, where: is_nil(w.closed_at), select: w.card_id)),
      select: {c.id, m.at}
    )
    |> in_trees(owned)
    |> live()
    |> Slipdock.Snooze.not_snoozed(now)
    |> Repo.all()
    |> Enum.map(fn {id, at} -> %{card_id: id, reason: "needs_owner", since: at} end)
  end

  defp load_cards([]), do: %{}

  defp load_cards(ids) do
    from(c in Card, where: c.id in ^ids)
    |> Repo.all()
    |> Repo.preload([:board, :column, :tags, :assignees])
    |> Map.new(&{&1.id, &1})
  end

  defp in_scope?(card, opts) do
    (is_nil(opts[:board_id]) or in_tree?(card, opts[:board_id])) and
      (is_nil(opts[:roots]) or Board.root_id(card.board) in opts[:roots])
  end

  # When each flag came on, for the cards that have it now: the first entry
  # of the newest unbroken run of "set flags" activity that includes it.
  # A card flagged when it was made has no such entry and counts from then.
  defp flag_since([]), do: %{}

  defp flag_since(card_ids) do
    from(a in Activity,
      where: a.card_id in ^card_ids and like(a.message, "set flags on %"),
      order_by: [asc: a.inserted_at, asc: a.id],
      select: {a.card_id, a.message, a.inserted_at}
    )
    |> Repo.all()
    |> Enum.group_by(&elem(&1, 0), &{flags_set(elem(&1, 1)), elem(&1, 2)})
    |> Enum.flat_map(fn {id, rows} ->
      for flag <- ~w(review waiting), at = run_start(rows, flag), do: {{id, flag}, at}
    end)
    |> Map.new()
  end

  # "set flags on “Title” to review, waiting" → ["review", "waiting"]
  defp flags_set(message) do
    case message |> String.split("” to ") |> List.last() do
      "none" -> []
      list -> String.split(list, ", ")
    end
  end

  defp run_start(rows, flag) do
    Enum.reduce(rows, nil, fn {flags, at}, start ->
      cond do
        flag not in flags -> nil
        start -> start
        true -> at
      end
    end)
  end

  # A card is in a board's tree when that board is its own or one of its
  # ancestors' — the same test the board page's rollup makes.
  defp in_tree?(%Card{board: board}, board_id) do
    board.id == board_id or Enum.any?(Boards.ancestry(board), &(&1.board.id == board_id))
  end
end
