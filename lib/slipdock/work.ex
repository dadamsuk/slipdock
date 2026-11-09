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
  alias Slipdock.Work.{Dismissal, Mute}
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

  # The reasons that head the list, whatever their age.
  @first ~w(overseer circling)

  @doc """
  Everything that needs `user` (#1118, R14), oldest first: one item per card,
  `%{card:, path:, reason:, text:, since:, cause:, wait:, job:, condition:}`,
  where `reason` is the first of these that applies:

    * `"overseer"` — an open condition the overseer's watch raised (#2068,
      `Slipdock.Overseer.Watch`) on a tree `user` owns, about this card:
      looping, waiting while idle, slow, idle capacity or no way forward.
      These come first, with circling cards, whatever their age;
    * `"circling"` — a card going round in circles (#2047): rejected twice
      or more and still flagged `review`, not yet accepted, in a tree
      `user` owns (`Slipdock.Verified.Circling`). These come first,
      whatever their age;
    * `"wait"` — an open wait on `user`;
    * `"wait_anyone"` — an open wait on anyone, on a card in a tree `user`
      owns or a card assigned to them (not one they asked themselves);
    * `"verify"` — a card an agent submitted, waiting for verification
      (#1624), in a tree `user` owns: they can accept or reject it. Not
      while a runner has it in hand (#2125): a verify job for it claimed or
      running, or, for `verify_grace_seconds/0` after its submission, one
      queued or a runner of its board's verify pool online. With no
      verifier it shows at once;
    * `"review"`, `"waiting"` — a card assigned to `user` flagged so
      (`waiting` only without an open wait, which says who it is on);
    * `"gave_up"` — a card the runner gave up on and flagged blocked, in a
      tree `user` owns;
    * `"failed"` — a card whose newest runner job failed or timed out, in a
      tree `user` owns, until a newer job is queued. Not a merge that
      failed for a reason a rebase fixes (`Slipdock.Verified.rebase_fixes?/1`)
      while a build job is claimed or running on the card or a card above
      it (#2568): a runner already has the rework in hand;
    * `"needs_owner"` — in a tree `user` owns, an open card in a doing list
      for over an hour with nobody on it, no open job and no open wait.

  `since` is when it started needing them: the newest rejection, the wait's opening, the newest
  run of the flag (from the activity log), the job's end, the card's entry
  into its list. Only cards `user` may read come back; completed and
  archived ones never do, and snoozed ones only for a wait. Nor do cards on
  a *Getting Started* board (`Slipdock.Onboarding`): the tour's cards are
  instructions for a person, and left there they would drown the rest.

  Options: `:board_id` keeps one board's tree, `:roots` the trees of those
  root boards (a token's scope), `:paths` false skips working out each
  card's path (for the count), `:now` for tests.
  """
  def waiting_on_me(%User{} = user, opts \\ []), do: waiting(user, opts).items

  @doc """
  `waiting_on_me/2` with what its person hid from it (#2069): `%{items:,
  dismissed:, muted:, muted_boards:}`. `items` is the list; `dismissed` the
  items they dismissed whose cause still stands, in the same shape and
  order; `muted` how many cards their muted boards keep off; `muted_boards`
  how many boards they have muted. Each item carries its `cause`, the key a
  dismissal is held on: the same cause stays dismissed, a new one shows.

  A card whose top reason is dismissed shows for its next reason, if it
  has one: that is a different cause.
  """
  def waiting(%User{} = user, opts \\ []) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    owned = owned_roots(user, opts[:roots])
    assigned = assigned_ids(user)

    candidates =
      overseer(owned) ++
        circling(owned) ++
        waits_on(user, owned, assigned) ++
        awaiting(owned, now) ++
        flagged(user, now) ++
        job_trouble(owned) ++ unowned(owned, now) ++ scheduled_missed(owned, user, now)

    cards =
      candidates
      |> Enum.map(& &1.card_id)
      |> Enum.uniq()
      |> load_cards()

    readable = user |> Access.filter_readable_cards(Map.values(cards)) |> MapSet.new(& &1.id)

    flag_since =
      flag_since(
        for %{reason: r, card_id: id} <- candidates,
            Enum.member?(~w(review waiting), r),
            do: id
      )

    muted = muted_board_ids(user)
    tour = tour_roots(cards)

    {muted_cards, found} =
      candidates
      |> Enum.filter(
        &(MapSet.member?(readable, &1.card_id) and in_scope?(cards[&1.card_id], opts))
      )
      |> Enum.reject(&MapSet.member?(tour, Board.root_id(cards[&1.card_id].board)))
      |> Enum.map(&candidate_item(&1, cards[&1.card_id], flag_since))
      |> Enum.group_by(& &1.card.id)
      |> Enum.split_with(fn {_id, [i | _]} -> muted?(i.card, muted) end)

    {shown, dismissed} = found |> Enum.map(&pick(&1, dismissed_causes(user))) |> split_picked()

    %{
      items: finish(shown, opts),
      dismissed: finish(dismissed, opts),
      muted: length(muted_cards),
      muted_boards: MapSet.size(muted)
    }
  end

  defp candidate_item(found, card, flag_since) do
    since = found[:since] || flag_since[{card.id, found.reason}] || card.inserted_at
    since = DateTime.truncate(since, :second)

    %{
      card: card,
      reason: found.reason,
      text: reason_text(found),
      since: since,
      cause: cause(found, since),
      wait: found[:wait],
      job: found[:job],
      condition: found[:condition]
    }
  end

  # What a dismissal is held on: the thing that put the card on the list.
  defp cause(%{reason: "overseer", condition: c}, _since), do: "overseer:#{c.id}"
  defp cause(%{reason: "circling", rejections: n}, _since), do: "circling:#{n}"
  defp cause(%{reason: "wait" <> _, wait: w}, _since), do: "wait:#{w.id}"
  defp cause(%{reason: r, job: %{id: id}}, _since) when r in ~w(gave_up failed), do: "job:#{id}"
  defp cause(%{reason: r}, since) when r in ~w(review waiting), do: "flag:#{r}:#{unix(since)}"
  defp cause(%{reason: r}, since), do: "#{r}:#{unix(since)}"

  defp unix(at), do: DateTime.to_unix(at)

  # One card's reasons: the first not dismissed, or the first if all are.
  defp pick({_id, items}, dismissed) do
    items = Enum.sort_by(items, &rank/1)

    case Enum.reject(items, &MapSet.member?(dismissed, {&1.card.id, &1.cause})) do
      [first | _] -> {:shown, first}
      [] -> {:dismissed, hd(items)}
    end
  end

  defp split_picked(picked) do
    {for({:shown, i} <- picked, do: i), for({:dismissed, i} <- picked, do: i)}
  end

  defp finish(items, opts) do
    items
    |> Enum.map(&Map.put(&1, :path, if(opts[:paths] == false, do: nil, else: path(&1.card))))
    |> Enum.sort_by(&{not Enum.member?(@first, &1.reason), &1.since, &1.card.id}, &older_first/2)
  end

  # Overseer conditions (#2068) and circling cards (#2047) first, then
  # oldest first, then by id.
  defp older_first({c, a, i}, {c, b, j}), do: order(DateTime.compare(a, b), i, j)
  defp older_first({not_circling, _, _}, _), do: not not_circling

  defp order(:eq, i, j), do: i <= j
  defp order(cmp, _i, _j), do: cmp == :lt

  @overseer_shown 5

  @doc """
  What `whoami` says about `user` (#2068): how many things wait on them
  (`waiting_count/2`) and the overseer's open conditions among them, first
  and at most `@overseer_shown` of them, as `{count, [condition]}`.
  """
  def waiting_summary(%User{} = user, opts \\ []) do
    items = waiting_on_me(user, Keyword.put(opts, :paths, false))
    {length(items), overseer_first(items)}
  end

  @doc """
  The overseer's conditions at the head of `items` (from `waiting/2`), at
  most `@overseer_shown` of them.
  """
  def overseer_first(items),
    do: for(%{reason: "overseer", condition: c} <- Enum.take(items, @overseer_shown), do: c)

  @doc "How many things are waiting on `user`: the length of `waiting_on_me/2`."
  def waiting_count(%User{} = user, opts \\ []),
    do: user |> waiting_on_me(Keyword.put(opts, :paths, false)) |> length()

  @reasons ~w(overseer circling wait wait_anyone verify review waiting gave_up failed needs_owner scheduled_missed)
  defp rank(%{reason: reason}), do: Enum.find_index(@reasons, &(&1 == reason))

  @doc "The reasons an item can have, in the order one card's are chosen from."
  def reasons, do: @reasons

  defp reason_text(%{reason: "overseer", condition: c}), do: "Overseer: #{c.title}"

  defp reason_text(%{reason: "circling", rejections: n}),
    do: "Going round in circles: rejected #{n} times"

  defp reason_text(%{reason: "wait", wait: w}), do: "Waiting on you: #{w.needs}"
  defp reason_text(%{reason: "wait_anyone", wait: w}), do: "Waiting on anyone: #{w.needs}"
  defp reason_text(%{reason: "verify"}), do: "Awaiting verification: accept or reject it"
  defp reason_text(%{reason: "review"}), do: "Flagged review"
  defp reason_text(%{reason: "waiting"}), do: "Flagged waiting"

  defp reason_text(%{reason: "gave_up", job: j}),
    do: "The runner gave up on it after job ##{j.id}"

  defp reason_text(%{reason: "failed", job: %{status: "timeout"} = j}),
    do: "Job ##{j.id} timed out"

  defp reason_text(%{reason: "failed", job: j}), do: "Job ##{j.id} failed"
  defp reason_text(%{reason: "needs_owner"}), do: "In progress with nobody on it"

  defp reason_text(%{reason: "scheduled_missed", due: due}),
    do: "Scheduled for #{Calendar.strftime(due, "%a %-d %b")}, not started"

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

  # The overseer's open conditions (#2068) on the owned trees, each on the
  # card it names. The newest on a card speaks for it.
  defp overseer([]), do: []

  defp overseer(owned) do
    owned
    |> Slipdock.Overseer.open_conditions()
    |> Enum.reject(&is_nil(&1.card_id))
    |> Enum.map(&%{card_id: &1.card_id, reason: "overseer", since: &1.opened_at, condition: &1})
  end

  # The root boards among `cards`' trees that are a Getting Started tour.
  defp tour_roots(cards) do
    roots = cards |> Map.values() |> Enum.map(&Board.root_id(&1.board)) |> Enum.uniq()

    from(b in Board,
      where: b.id in ^roots and b.name == ^Slipdock.Onboarding.board_name(),
      select: b.id
    )
    |> Repo.all()
    |> MapSet.new()
  end

  # Cards going round in circles (#2047): rejected twice or more, still
  # flagged review and not yet accepted. The same test as
  # `Slipdock.Verified.Circling.circling?/1`.
  defp circling([]), do: []

  defp circling(owned) do
    from(c in Card,
      where: c.verify_rejections >= ^Slipdock.Verified.Circling.threshold(),
      where: c.verify_state in ["rejected", "pending"],
      where: fragment("? = ANY(?)", "review", c.flags),
      select: {c.id, c.verify_rejections, c.verify_at}
    )
    |> in_trees(owned)
    |> live()
    |> Repo.all()
    |> Enum.map(fn {id, n, at} ->
      %{card_id: id, reason: "circling", rejections: n, since: at}
    end)
  end

  # Cards an agent submitted on a board that verifies work (#1624), less
  # those a runner is about to verify (#2125).
  defp awaiting([], _now), do: []

  defp awaiting(owned, now) do
    rows =
      from(c in Card, where: c.verify_state == "pending")
      |> in_trees(owned)
      |> live()
      |> select([c, b], {c.id, c.verify_at, b.verify_pool, coalesce(b.root_id, b.id)})
      |> Repo.all()

    verifying = verifier_on(rows, now)

    for {id, at, _pool, _root} = row <- rows, not verifying.(row) do
      %{card_id: id, reason: "verify", since: at}
    end
  end

  @verify_grace_seconds 15 * 60

  @doc """
  How long a card pending verification stays off Waiting on you while a
  verify runner for its tree is online, or its verify job is queued, but
  no verify job has started on it (#2125): counted from its submission.
  """
  def verify_grace_seconds, do: @verify_grace_seconds

  # Whether a runner has the card's verification in hand: a verify job for
  # it started (claimed or running), or, within the grace period after its
  # submission, one queued or a runner of its board's verify pool online.
  defp verifier_on([], _now), do: fn _row -> false end

  defp verifier_on(rows, now) do
    ids = Enum.map(rows, &elem(&1, 0))

    jobs =
      from(j in Job,
        where: j.card_id in ^ids and j.kind == ^Slipdock.Verified.verify_kind(),
        where: j.status in ["queued", "claimed", "running"],
        select: {j.card_id, j.status}
      )
      |> Repo.all()
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))

    online = online_pools(rows, now)

    fn {id, at, pool, root} ->
      statuses = Map.get(jobs, id, [])

      Enum.any?(statuses, &(&1 != "queued")) or
        (in_grace?(at, now) and (statuses != [] or MapSet.member?(online, {root, pool})))
    end
  end

  defp in_grace?(nil, _now), do: false
  defp in_grace?(at, now), do: DateTime.diff(now, at) < @verify_grace_seconds

  # `{root board id, pool}` of each runner online in the rows' verify pools.
  defp online_pools(rows, now) do
    roots = for {_, _, pool, root} <- rows, is_binary(pool), uniq: true, do: root

    from(r in Slipdock.Runners.Runner,
      where: r.board_id in ^roots and not is_nil(r.last_seen_at)
    )
    |> Repo.all()
    |> Enum.filter(&(DateTime.diff(now, &1.last_seen_at) <= 3 * Slipdock.Runners.lease_for(&1)))
    |> MapSet.new(&{&1.board_id, &1.pool})
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
    |> reject_in_hand()
    |> Enum.map(fn j ->
      %{
        card_id: j.card_id,
        reason: if(j.recovery == "gave_up", do: "gave_up", else: "failed"),
        since: j.finished_at || j.updated_at,
        job: j
      }
    end)
  end

  # Leaves out a failed merge a rebase fixes while a runner is reworking the
  # card (#2568): a build job claimed or running on it or on a card above
  # it. An epic's build job works its subcards in that one job, so no newer
  # job is queued on the subcard itself. Any other failure still shows.
  defp reject_in_hand(jobs) do
    case Enum.filter(jobs, &rebase_fixes?/1) do
      [] ->
        jobs

      merges ->
        lines = Map.new(merges, &{&1.card_id, card_line(&1.card_id)})
        building = building(lines |> Map.values() |> List.flatten() |> Enum.uniq())

        Enum.reject(jobs, fn j ->
          Map.has_key?(lines, j.card_id) and
            Enum.any?(lines[j.card_id], &MapSet.member?(building, &1))
        end)
    end
  end

  defp rebase_fixes?(%Job{status: "failed", recovery: r} = job) when r != "gave_up",
    do:
      job.kind == Slipdock.Verified.merge_kind() and
        Slipdock.Verified.rebase_fixes?(merge_said(job))

  defp rebase_fixes?(_job), do: false

  # The merge job's own words, as `Slipdock.Verified` reads them: its last
  # `merge:` line, else the output's last line.
  defp merge_said(job) do
    lines = (job.output || job.log_tail || "") |> String.split(~r/\R/, trim: true)
    Enum.find(Enum.reverse(lines), &String.starts_with?(&1, "merge:")) || List.last(lines)
  end

  # The card and every card above it.
  defp card_line(card_id) do
    card = Card |> Repo.get!(card_id) |> Repo.preload(:board)
    [card_id | Enum.map(Boards.ancestry(card.board), & &1.card.id)]
  end

  # Those of `card_ids` with a build job claimed or running on them.
  defp building(card_ids) do
    not_builds = [Slipdock.Overseer.kind() | Slipdock.Verified.finishing_kinds()]

    from(j in Job,
      where: j.card_id in ^card_ids and j.status in ["claimed", "running"],
      where: j.kind not in ^not_builds,
      distinct: true,
      select: j.card_id
    )
    |> Repo.all()
    |> MapSet.new()
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

  # A card left in a Scheduled list (#2100) past the end of its due day, in
  # its board owner's time zone: whatever was to take it from there didn't.
  defp scheduled_missed([], _user, _now), do: []

  defp scheduled_missed(owned, user, now) do
    zone = user.timezone || "Etc/UTC"
    today = Slipdock.Timezones.today(zone, now)

    from(c in Card,
      join: col in Column,
      on: col.id == c.column_id and col.category == "scheduled",
      where: not is_nil(c.due_date) and c.due_date < ^today,
      select: {c.id, c.due_date}
    )
    |> in_trees(owned)
    |> live()
    |> Slipdock.Snooze.not_snoozed(now)
    |> Repo.all()
    |> Enum.map(fn {id, due} ->
      %{
        card_id: id,
        reason: "scheduled_missed",
        due: due,
        since: Slipdock.Timezones.to_utc(Date.add(due, 1), ~T[00:00:00], zone)
      }
    end)
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

  ## Dismissing and muting (#2069)

  @doc """
  Takes the card's item off `user`'s own Waiting on you, held on its cause:
  `{:ok, item}`, or `{:error, :not_waiting}` when the card isn't on their
  list. Nobody else's list changes.
  """
  def dismiss(%User{} = user, %Card{} = card) do
    case Enum.find(waiting(user, board_id: card.board_id).items, &(&1.card.id == card.id)) do
      nil ->
        {:error, :not_waiting}

      item ->
        %Dismissal{user_id: user.id, card_id: card.id, reason: item.reason, cause: item.cause}
        |> Repo.insert!(on_conflict: :nothing, conflict_target: [:user_id, :card_id, :cause])

        {:ok, item}
    end
  end

  @doc """
  Undoes `user`'s dismissals of the card: `{:ok, count}`, or
  `{:error, :not_dismissed}` when they had none.
  """
  def undismiss(%User{} = user, %Card{} = card) do
    case Repo.delete_all(
           from(d in Dismissal, where: d.user_id == ^user.id and d.card_id == ^card.id)
         ) do
      {0, _} -> {:error, :not_dismissed}
      {n, _} -> {:ok, n}
    end
  end

  @doc "The items `user` dismissed whose cause still stands, as `waiting/2` gives them."
  def dismissed(%User{} = user, opts \\ []), do: waiting(user, opts).dismissed

  @doc """
  Keeps the board's tree off `user`'s own Waiting on you: `{:ok, board}`.
  Muting again is a no-op.
  """
  def mute(%User{} = user, %Board{} = board) do
    %Mute{user_id: user.id, board_id: board.id}
    |> Repo.insert!(on_conflict: :nothing, conflict_target: [:user_id, :board_id])

    {:ok, board}
  end

  @doc "Lifts `user`'s mute of the board: `{:ok, board}` or `{:error, :not_muted}`."
  def unmute(%User{} = user, %Board{} = board) do
    case Repo.delete_all(
           from(m in Mute, where: m.user_id == ^user.id and m.board_id == ^board.id)
         ) do
      {0, _} -> {:error, :not_muted}
      _ -> {:ok, board}
    end
  end

  @doc "The boards `user` has muted, by name."
  def muted_boards(%User{} = user) do
    from(b in Board,
      join: m in Mute,
      on: m.board_id == b.id and m.user_id == ^user.id,
      order_by: [asc: b.name, asc: b.id]
    )
    |> Repo.all()
  end

  @doc """
  The board whose mute keeps this board off `user`'s list: the board itself
  or one above it, nearest first, or `nil` when it isn't muted for them.
  """
  def muted_by(%User{} = user, %Board{} = board) do
    muted = muted_board_ids(user)

    cond do
      MapSet.size(muted) == 0 -> nil
      MapSet.member?(muted, board.id) -> board
      true -> board |> Boards.ancestry() |> Enum.reverse() |> find_muted(muted)
    end
  end

  defp find_muted(chain, muted) do
    Enum.find_value(chain, fn %{board: b} -> if MapSet.member?(muted, b.id), do: b end)
  end

  defp muted_board_ids(user) do
    from(m in Mute, where: m.user_id == ^user.id, select: m.board_id)
    |> Repo.all()
    |> MapSet.new()
  end

  defp dismissed_causes(user) do
    from(d in Dismissal, where: d.user_id == ^user.id, select: {d.card_id, d.cause})
    |> Repo.all()
    |> MapSet.new()
  end

  defp muted?(%Card{board: board}, muted) do
    MapSet.size(muted) > 0 and
      (MapSet.member?(muted, board.id) or MapSet.member?(muted, Board.root_id(board)) or
         Enum.any?(Boards.ancestry(board), &MapSet.member?(muted, &1.board.id)))
  end
end
