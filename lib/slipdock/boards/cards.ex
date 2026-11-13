defmodule Slipdock.Boards.Cards do
  @moduledoc """
  Cards: made, read, changed, moved within a board, archived and deleted,
  with their assignees, tags, timers and stand-ins. Every change is offered
  to `Slipdock.Automations` and re-indexed for search.
  """

  import Ecto.Query, warn: false

  alias Slipdock.Accounts.User
  alias Slipdock.Boards
  alias Slipdock.Boards.Board
  alias Slipdock.Boards.Card
  alias Slipdock.Boards.CardLink
  alias Slipdock.Boards.Column
  alias Slipdock.Boards.Handoff
  alias Slipdock.Boards.ShortNames
  alias Slipdock.Boards.Wait
  alias Slipdock.CardState
  alias Slipdock.Quota
  alias Slipdock.Repo
  alias Slipdock.Rollup
  alias Slipdock.Search.Indexer
  alias Slipdock.Swimlanes
  alias Slipdock.Swimlanes.Config
  alias Slipdock.Wiki.CardFolders

  @unassigned ~w(none nobody unassigned)

  defp link_query, do: from(l in CardLink, order_by: [asc: l.kind, asc: l.id])

  defp link_stub_query do
    from(c in Card,
      select: [:id, :title, :completed, :archived_at, :board_id, :column_id, :priority, :due_date]
    )
  end

  defp board_stub_query,
    do: from(b in Board, select: [:id, :name, :code, :root_id, :parent_card_id, :color])

  # A card's sub-board is loaded as a summary: its lists and the state of its cards.
  defp sub_board_query do
    from(b in Board, select: [:id, :name, :parent_card_id, :root_id, :template_id])
  end

  defp sub_board_preloads do
    [
      columns:
        from(c in Column,
          order_by: c.position,
          select: [:id, :name, :position, :color, :board_id]
        ),
      # In board order (list, then place in the list), so callers that show
      # or compare subcards see them as the board does, not as the rows fell.
      cards:
        from(c in Card,
          join: col in assoc(c, :column),
          where: is_nil(c.archived_at),
          order_by: [asc: col.position, asc: c.position, asc: c.id],
          # `verify_state`: subcards awaiting verification (#1624).
          select: [:id, :title, :completed, :archived_at, :board_id, :column_id, :verify_state]
        )
    ]
  end

  # What a stand-in shows of the card it stands for: where that card is now
  # (its list's category, not its list's name, since the two boards' lists
  # need not match) and the sprint holding it.
  defp stand_in_target_query do
    from(c in Card, select: [:id, :title, :completed, :archived_at, :board_id, :column_id])
  end

  defp stand_in_target_preloads do
    [
      column: from(c in Column, select: [:id, :name, :category, :board_id]),
      board:
        {from(b in Board, select: [:id, :name, :parent_card_id, :root_id]),
         parent_card: from(c in Card, select: [:id, :title, :board_id])}
    ]
  end

  # Each card's newest handoff row, for a preload: one per card.
  defp newest_handoff_query do
    from(h in Handoff,
      as: :handoff,
      where:
        h.id ==
          subquery(
            from(n in Handoff,
              where: n.card_id == parent_as(:handoff).card_id,
              select: max(n.id)
            )
          )
    )
  end

  defp open_wait_query, do: from(w in Wait, where: is_nil(w.closed_at))

  @doc false
  def card_preloads do
    [
      :tags,
      :assignee,
      :assignees,
      :checklist_items,
      [comments: :user],
      [attachments: :document_text],
      :urls,
      :status_updates,
      :votes,
      handoff: {newest_handoff_query(), :user},
      # Waiting on a person (#1114): the open wait, if there is one.
      wait: {open_wait_query(), Boards.Waits.wait_preloads()},
      # The series it is the current instance of, if it repeats (W-1802).
      recurrence: [],
      field_values: [:field],
      links_out: {link_query(), to: {link_stub_query(), [board: board_stub_query()]}},
      links_in: {link_query(), from: {link_stub_query(), [board: board_stub_query()]}},
      blocked_by: {Boards.dependency_query(), [board: board_stub_query()]},
      blocks: {Boards.dependency_query(), [board: board_stub_query()]},
      sub_board: {sub_board_query(), sub_board_preloads()},
      stand_in_for: {stand_in_target_query(), stand_in_target_preloads()}
    ]
  end

  ## Cards

  @doc """
  Active cards assigned to `user`, across every board, with their board,
  list, tags and rollup, ordered by due date then title.
  """
  def list_assigned_cards(%Slipdock.Accounts.User{} = user) do
    cards =
      from(c in Card,
        where: is_nil(c.archived_at),
        where:
          c.id in subquery(
            from(a in "card_assignees", where: a.user_id == ^user.id, select: a.card_id)
          ),
        order_by: [asc_nulls_last: c.due_date, asc: c.title]
      )
      |> Slipdock.Snooze.not_snoozed()
      |> Repo.all()
      |> Repo.preload([:board, :column, :tags, :assignee, :assignees])

    rollups =
      cards
      |> Enum.map(&Board.root_id(&1.board))
      |> Enum.uniq()
      |> Map.new(&{&1, Rollup.build(&1)})

    Enum.map(cards, &Rollup.put_stats(&1, rollups[Board.root_id(&1.board)]))
  end

  def get_card!(id) do
    Card
    |> Repo.get!(id)
    |> Repo.preload([:column | card_preloads()])
    |> with_rollup()
  end

  def get_card(nil), do: nil

  def get_card(id) do
    case Repo.get(Card, id) do
      nil -> nil
      card -> card |> Repo.preload([:column | card_preloads()]) |> with_rollup()
    end
  end

  @doc """
  Cards from `list_cards/2` on `board`, decorated as `get_card/1` decorates
  one: rollup stats and formula scores. One rollup for the tree, and the
  formulas computed across the board's open cards rather than just these, so
  a weighted score reads the same here as on the card.
  """
  def with_details(%Board{} = board, cards) when is_list(cards) do
    rollup = Rollup.build(Board.root_id(board))
    fields = Slipdock.Fields.list_fields(Board.root_id(board))
    cards = Enum.map(cards, &Rollup.put_stats(&1, rollup))

    if Enum.any?(fields, &(&1.kind == "formula")) do
      ids = Enum.map(cards, & &1.id)

      peers =
        from(c in Card,
          where: c.board_id == ^board.id and is_nil(c.archived_at) and c.id not in ^ids,
          select: [:id, :board_id, :completed],
          preload: [:field_values, :votes]
        )
        |> Repo.all()

      cards |> Kernel.++(peers) |> Slipdock.Fields.decorate(fields) |> Enum.take(length(cards))
    else
      Enum.map(cards, &Map.merge(&1, %{computed: %{}, scores: %{}}))
    end
  end

  defp with_rollup(%Card{} = card) do
    root_id =
      Repo.one!(
        from(b in Board, where: b.id == ^card.board_id, select: coalesce(b.root_id, b.id))
      )

    card
    |> Rollup.put_stats(Rollup.build(root_id))
    |> Slipdock.Fields.decorate_one(Slipdock.Fields.list_fields(root_id))
  end

  @doc """
  Lists cards on a board, filtered by a map of string keys:
  `"column"`, `"tag"`, `"priority"`, `"flag"`, `"q"`, `"completed"`,
  `"archived"`, `"assignee"`, `"due"`, `"deps"` and `"kind"`.

  `"q"` matches a piece of the title or description, and a card's id
  (`123`, `#123`) or link names that card as well (`card_ref/1`).

  `"kind"` is `"card"` or `"document"` (a card whose whole content is the file
  on it — see `Slipdock.Kinds`). Wiki pages are the third kind of thing in a
  list and are not cards: `Slipdock.Wiki.list_pages/2` lists those.

  `"due"` and `"deps"` take the buckets the board's views use
  (`Slipdock.Swimlanes.Config.dues/0` and `deps/0`): `"overdue"`, `"today"`,
  `"week"`, `"month"`, `"has"`, `"none"`, and `"blocked"`, `"ready"`,
  `"blocking"`, `"violated"`, `"free"`. A value that is not one of them is
  ignored rather than raising, because these arrive from query strings.

  `"assignee"` matches a person's email exactly or their name loosely, takes
  an id, and takes `"none"` (or `"unassigned"`) for the cards nobody owns.

  Archived cards are left out unless `"archived"` says otherwise: `"true"`
  for the archived ones alone, `"all"` (or `"include"`) for both.

  Snoozed cards (W-1803) are left out too, unless `"snoozed"` is
  `"include"` (both) or `"only"` (see `Slipdock.Snooze.filter/3`).

  Every card comes back with its `state` (`Slipdock.CardState`), and two
  filters read it (#1117): `"stuck"` (`true`) for the cards past their
  list's usual stay, and `"driver"` (`"agent"` or `"human"`; `"all"` is no
  filter) for who is driving the card.

  `"origin"` (#2778) keeps the cards one of `Slipdock.Origin.names/0` made,
  or with `"none"` those made before origins were kept.
  """
  def list_cards(%Board{} = board, filters \\ %{}) do
    board
    |> cards_query(filters)
    |> Repo.all()
    |> Repo.preload(card_preloads())
    |> CardState.put(board)
    |> filter_loaded(board, filters)
  end

  # The filters the database applies.
  defp cards_query(board, filters) do
    from(c in Card,
      where: c.board_id == ^board.id,
      join: col in assoc(c, :column),
      order_by: [asc: col.position, asc: c.position],
      preload: [column: col]
    )
    |> archived_filter(filters["archived"])
    |> Slipdock.Snooze.filter(filters["snoozed"])
    |> column_filter(board, filters["column"])
    |> priority_filter(filters["priority"])
    |> origin_filter(filters["origin"])
    |> completed_filter(filters["completed"])
    |> text_filter(filters["q"])
  end

  # The filters that read what was loaded: the card's state, flags, tags,
  # dates, dependencies, people and kind.
  defp filter_loaded(cards, board, filters) do
    cards
    |> Enum.filter(
      &CardState.matches?(&1, Enum.member?([true, "true"], filters["stuck"]), filters["driver"])
    )
    |> filter_flag(filters["flag"])
    |> filter_tag(board, filters["tag"])
    |> filter_due(filters["due"])
    |> filter_deps(filters["deps"])
    |> filter_assignee(filters["assignee"])
    |> filter_kind(filters["kind"])
  end

  defp archived_filter(query, archived) do
    cond do
      Enum.member?([true, "true"], archived) -> where(query, [c], not is_nil(c.archived_at))
      Enum.member?(["all", "include"], archived) -> query
      true -> where(query, [c], is_nil(c.archived_at))
    end
  end

  defp column_filter(query, _board, nil), do: query

  defp column_filter(query, board, ref) do
    case Boards.find_column(board, ref) do
      {:ok, col} -> where(query, [c], c.column_id == ^col.id)
      _ -> where(query, [c], false)
    end
  end

  defp priority_filter(query, nil), do: query
  defp priority_filter(query, p), do: where(query, [c], c.priority == ^p)

  defp completed_filter(query, nil), do: query

  defp completed_filter(query, v),
    do: where(query, [c], c.completed == ^Enum.member?([true, "true"], v))

  defp text_filter(query, nil), do: query

  defp text_filter(query, q) do
    like = "%" <> String.downcase(q) <> "%"

    where(
      query,
      [c],
      fragment("(? = ? OR lower(?) LIKE ?)", c.id, ^ref_id(q), c.title, ^like) or
        like(fragment("lower(?)", c.description), ^like)
    )
  end

  defp filter_flag(cards, nil), do: cards
  defp filter_flag(cards, flag), do: Enum.filter(cards, &Enum.member?(&1.flags, flag))

  defp filter_tag(cards, _board, nil), do: cards

  defp filter_tag(cards, board, ref) do
    case Boards.find_tag(board, ref) do
      {:ok, tag} -> Enum.filter(cards, fn c -> Enum.any?(c.tags, &(&1.id == tag.id)) end)
      _ -> []
    end
  end

  # Documents are recognised from what a card holds rather than stored, so
  # this one filters in memory over the loaded cards (see `Slipdock.Kinds`).
  defp filter_kind(cards, kind) when is_binary(kind) and kind != "" do
    if Enum.member?(Slipdock.Kinds.keys(), kind),
      do: Enum.filter(cards, &Slipdock.Kinds.matches?(&1, [kind])),
      else: cards
  end

  defp filter_kind(cards, _), do: cards

  # The date and dependency buckets are the board views' own (see
  # `Slipdock.Swimlanes`), so "overdue" means the same thing in a swimlane, in
  # the API and to the assistant.
  defp filter_due(cards, bucket) when is_binary(bucket) do
    if Enum.member?(Enum.map(Config.dues(), &elem(&1, 0)), bucket) and bucket != "",
      do: Enum.filter(cards, &Swimlanes.due_matches?(bucket, &1)),
      else: cards
  end

  defp filter_due(cards, _), do: cards

  defp filter_deps(cards, bucket) when is_binary(bucket) do
    if Enum.member?(Enum.map(Config.deps(), &elem(&1, 0)), bucket) and bucket != "",
      do: Enum.filter(cards, &Swimlanes.deps_matches?(bucket, &1)),
      else: cards
  end

  defp filter_deps(cards, _), do: cards

  defp filter_assignee(cards, ref) when is_binary(ref) do
    case String.downcase(String.trim(ref)) do
      "" -> cards
      wanted when wanted in @unassigned -> Enum.filter(cards, &(Card.assignees(&1) == []))
      wanted -> Enum.filter(cards, &assignee_matches?(&1, wanted))
    end
  end

  defp filter_assignee(cards, _), do: cards

  # A card matches if any of the people on it does.
  defp assignee_matches?(%Card{} = card, wanted) do
    Enum.any?(Card.assignees(card), fn user ->
      String.downcase(user.email) == wanted or
        String.contains?(String.downcase(user.name || ""), wanted) or
        to_string(user.id) == wanted
    end)
  end

  @doc "Replaces the card's tags with the given list of `%Tag{}`s."
  def set_card_tags(%Card{} = card, tags) when is_list(tags) do
    card = Repo.preload(card, :tags)

    card
    |> Ecto.Changeset.change()
    |> Ecto.Changeset.put_assoc(:tags, tags)
    |> Repo.update()
    |> Boards.Shared.tap_ok(fn updated ->
      Boards.PubSub.broadcast(updated.board_id)
      Indexer.enqueue(updated)
      Boards.CardEvents.automate_tags_added(updated, card.tags, tags)
    end)
  end

  @doc """
  Moves a card into a column at a 0-based `index` (`:top`, `:bottom`, or an
  integer). Convenience wrapper over `move_card/4`, whose `opts` it takes.
  """
  def move_card_to_index(%Card{} = card, %Column{} = column, index, opts \\ []) do
    # The index counts everything in the list, wiki pages included: "second
    # from the top" means what a reader sees, not what the cards table says.
    items = Boards.Columns.active_items(column.id) |> List.delete({:card, card.id})

    before_ref =
      case index do
        :top -> List.first(items)
        :bottom -> nil
        i when is_integer(i) and i >= 0 -> Enum.at(items, i)
        _ -> nil
      end

    move_card(card.id, column.id, before_ref, opts)
  end

  @doc """
  A copy of `card` as it is now, into `column` (nil: its own list). See
  `Slipdock.Boards.Copy` for what is and isn't carried over, and the options.
  """
  defdelegate copy_card(card, column \\ nil, opts \\ []), to: Slipdock.Boards.Copy

  @doc """
  Adds a card to `column`. `opts[:by]` is the person writing it, when known:
  it is who anybody `@mentioned` in the description is told mentioned them
  (see `Slipdock.Mentions`).
  """
  def create_card(%Column{} = column, attrs, opts \\ []) do
    position = Boards.Shared.next_position(from(c in Card, where: c.column_id == ^column.id))
    card = %Card{board_id: column.board_id, column_id: column.id, position: position}

    # An incident's cause (#1946): a card the writer can read, or a refusal.
    case Slipdock.Incidents.check(card, attrs, writer(opts), opts[:token]) do
      {:ok, attrs} ->
        with {:ok, card, attrs} <- put_origin(card, attrs, opts),
             do: insert_card(card, column, attrs, opts)

      {:error, field, message} ->
        {:error, refused(card, field, message)}
    end
  end

  # The cards whose origin (#2778) is `origin`; "none" for those with none.
  defp origin_filter(query, origin) when origin in [nil, "", "all"], do: query
  defp origin_filter(query, "none"), do: where(query, [c], is_nil(c.origin))
  defp origin_filter(query, origin), do: where(query, [c], c.origin == ^origin)

  # Who or what made the card (#2778, `Slipdock.Origin`): the server's own
  # say in `opts[:origin]`, else what the actor is; a caller's `"origin"`
  # in `attrs` may only name a generator from inside a runner job.
  defp put_origin(card, attrs, opts) do
    {requested, attrs} = pop_origin(attrs)

    case Slipdock.Origin.resolve(actor_or_current(opts), opts[:by], opts[:origin], requested) do
      {:ok, {origin, job_id}} -> {:ok, %{card | origin: origin, origin_job_id: job_id}, attrs}
      {:error, message} -> {:error, refused(card, :origin, message)}
    end
  end

  defp pop_origin(attrs) do
    {given, attrs} = Map.pop(attrs, "origin")
    {atom, attrs} = Map.pop(attrs, :origin)
    {given || atom, attrs}
  end

  defp insert_card(card, column, attrs, opts) do
    {assignees, attrs} = assignee_change(card, attrs)
    attrs = Slipdock.TimeTracking.normalize_attrs(card, attrs)

    card
    |> Card.changeset(Map.put(attrs, "board_id", column.board_id))
    |> profile_source(opts)
    # The free tier's limit, enforced here rather than in the board UI: the
    # same card can be made from quick add, the CLI, the JSON API, an
    # automation rule and the model, and all of them come through this
    # function. See `Slipdock.Quota`.
    |> Quota.enforce(column)
    # Created straight into a doing list (#1815), the card meets the checks
    # a move into it makes: the bar (#1620), then lanes (#1628).
    |> Slipdock.Verified.check_create(column, Slipdock.Actor.resolve(opts))
    |> Slipdock.Lanes.check_create(column, Slipdock.Actor.resolve(opts))
    |> save_with_assignees(&Repo.insert/1, assignees)
    |> Boards.Shared.tap_ok(fn card ->
      Boards.ActivityLog.log(
        Repo,
        card.board_id,
        card.id,
        "card",
        "added “#{card.title}” to #{column.name}"
      )

      Boards.Moves.record_move(card, "created", nil, column, creator(opts))
      # Created straight into a doing list by an agent, it is started (#1951).
      started(card.id, column, Slipdock.Actor.resolve(opts))
      Boards.PubSub.broadcast(card.board_id)
      Indexer.enqueue(card)
      if ShortNames.stale?(nil, card), do: ShortNames.refine_later(card)
      Slipdock.Mentions.description_changed(card, nil, card.description, opts[:by])
      if card.missed_by, do: Slipdock.Findings.Signals.incident(card, writer_name(opts))
      Boards.CardEvents.automate(%{type: "card_created", card: card, column: column})
    end)
  end

  # The incident's finding on its cause follows its fields (#1946).
  defp incident_saved(card, updated, opts) do
    if Slipdock.Incidents.changed?(card, updated),
      do: Slipdock.Findings.Signals.incident(updated, writer_name(opts))
  end

  # Who is writing, when a person's account is (`opts[:by]`).
  defp writer(opts) do
    case opts[:by] do
      %Slipdock.Accounts.User{} = user -> user
      _ -> nil
    end
  end

  defp writer_name(opts) do
    case writer(opts) do
      nil -> nil
      user -> user.name || user.email
    end
  end

  defp refused(card, field, message),
    do: card |> Ecto.Changeset.change() |> Ecto.Changeset.add_error(field, message)

  @doc """
  Gives `card` a profile (#1951) when `actor`, an agent, claims or starts it
  on a board with `profiles` on and it has none: inferred from its paths and
  tags by `Slipdock.Profiles.infer_card/2`, stored, logged and broadcast. A
  person, a rule or the assistant starting it infers nothing, and a profile
  already set is kept. Returns the card, with its profile if it got one.
  """
  def infer_profile(%Card{profile: nil} = card, actor) do
    board = Repo.get(Board, card.board_id)

    if board && board.profiles && Slipdock.Verified.gated?(actor) do
      profile = card |> Repo.preload(:tags) |> Slipdock.Profiles.infer_card()

      {:ok, updated} =
        card
        |> Ecto.Changeset.change(profile: profile, profile_source: "inferred")
        |> Repo.update()

      Boards.ActivityLog.log(
        Repo,
        updated.board_id,
        updated.id,
        "card",
        "profile inferred: #{profile}"
      )

      Boards.PubSub.broadcast(updated.board_id)
      updated
    else
      card
    end
  end

  def infer_profile(%Card{} = card, _actor), do: card

  # Where a profile a write sets came from (#2018): who wrote it, read from
  # `opts` and else from the process (`Slipdock.Actor.current/0`). Cleared
  # with the profile; a write that leaves the profile alone keeps it.
  defp profile_source(changeset, opts) do
    case Ecto.Changeset.fetch_change(changeset, :profile) do
      {:ok, nil} -> Ecto.Changeset.put_change(changeset, :profile_source, nil)
      {:ok, _} -> Ecto.Changeset.put_change(changeset, :profile_source, source_of(opts))
      :error -> changeset
    end
  end

  defp source_of(opts) do
    actor = actor_or_current(opts)

    case actor.kind do
      "human" -> "person"
      "agent" -> "agent"
      "automation" -> "rule"
      _ -> nil
    end
  end

  # The raise `Slipdock.Verified.profile_raise/3` found, as the server's
  # inference: it is the change, not the writer, that set it.
  defp raise_profile(changeset, nil), do: changeset

  defp raise_profile(changeset, %{profile: profile}),
    do: Ecto.Changeset.change(changeset, profile: profile, profile_source: "inferred")

  defp log_raise(_card, nil), do: nil

  defp log_raise(card, raised),
    do:
      Boards.ActivityLog.log(
        Repo,
        card.board_id,
        card.id,
        "card",
        Slipdock.Verified.raise_text(raised)
      )

  # Into a doing list, the card is started (#1951).
  defp started(card_id, %Column{category: "doing"}, actor),
    do: infer_profile(Repo.get!(Card, card_id), actor)

  defp started(_card_id, _column, _actor), do: nil

  @doc "Changes a card. `opts[:by]` as for `create_card/3`."
  def update_card(card, attrs, opts \\ [])

  # A stand-in has nothing of its own to change: everything it shows is the
  # real card's, and that is where a change belongs.
  def update_card(%Card{stand_in_for_id: id} = card, _attrs, _opts) when not is_nil(id) do
    {:error,
     card
     |> Ecto.Changeset.change()
     |> Ecto.Changeset.add_error(
       :stand_in_for_id,
       "is a stand-in for card ##{id} — change that card instead"
     )}
  end

  def update_card(%Card{} = card, attrs, opts) do
    # Verified work (#1620): what an agent may change on a board that checks.
    # A verifier's decision (`Slipdock.Verified.decide/5`) brings its own.
    # An incident's cause (#1946) first: a card the writer can read.
    checked =
      case {Slipdock.Incidents.check(card, attrs, writer(opts), opts[:token]),
            opts[:verify_changes]} do
        {{:error, _, _} = refused, _} -> refused
        {{:ok, attrs}, nil} -> check_update(card, attrs, Slipdock.Actor.resolve(opts))
        {{:ok, attrs}, changes} -> {:ok, attrs, changes}
      end

    case checked do
      {:ok, checked_attrs, changes} ->
        # An agent's completion with its actual change may raise the profile
        # (#2017): read from the write as sent, since on a board that
        # verifies work the checks turn a completion into a submission.
        raised =
          if is_nil(opts[:verify_changes]),
            do: Slipdock.Verified.profile_raise(card, attrs, Slipdock.Actor.resolve(opts))

        save_card(card, checked_attrs, changes, Keyword.put(opts, :profile_raise, raised))

      {:error, field, message} ->
        {:error, refused(card, field, message)}
    end
  end

  # Lanes (#1628) first, then Verified work (#1620).
  defp check_update(card, attrs, actor) do
    case Slipdock.Lanes.check_update(card, attrs, actor) do
      :ok -> Slipdock.Verified.check_update(card, attrs, actor)
      refused -> refused
    end
  end

  defp save_card(%Card{} = card, attrs, verify_changes, opts) do
    {assignees, attrs} = assignee_change(card, attrs)
    attrs = Slipdock.TimeTracking.normalize_attrs(card, attrs)
    # Who was on it, read only when this write changes that.
    before = if assignees, do: assignee_ids(card), else: []
    raised = opts[:profile_raise]

    changeset =
      card
      |> Card.changeset(attrs)
      |> Ecto.Changeset.change(verify_changes)
      |> percent_by_hand(opts)
      |> profile_source(opts)
      |> raise_profile(raised)

    titled? = Map.has_key?(changeset.changes, :title)
    named? = titled? or Map.has_key?(changeset.changes, :short_name)
    save = fn -> save_with_assignees(changeset, &Repo.update/1, assignees) end

    saved = %{
      changeset: changeset,
      before: before,
      assignees: assignees,
      opts: opts,
      raised: raised,
      titled?: titled?,
      named?: named?
    }

    if(named?, do: CardFolders.tracking(card, save), else: save.())
    |> Boards.Shared.tap_ok(&card_saved(card, &1, saved))
  end

  # Everything that follows a card's save: its log, the broadcast, search and
  # the hooks the changed fields set off.
  defp card_saved(card, updated, saved) do
    %{changeset: changeset, before: before, assignees: assignees, opts: opts} = saved

    (describe_card_changes(card, changeset) ++ describe_assignees(card, before, assignees))
    |> Enum.each(&Boards.ActivityLog.log(Repo, updated.board_id, updated.id, "card", &1))

    log_raise(updated, saved.raised)
    renamed(updated, saved.titled?, saved.named?)

    Boards.PubSub.broadcast(updated.board_id)
    Indexer.enqueue(updated)
    if ShortNames.stale?(card, updated), do: ShortNames.refine_later(updated)

    changed_hooks(card, updated, saved)
    assigned_hooks(updated, saved)

    # The epic's comments and % complete (#1881).
    Slipdock.EpicLog.saved(card, updated)

    # The step it is at, as a status update (#2022).
    Slipdock.StepStatus.saved(card, updated, Slipdock.Actor.resolve(opts))

    Boards.CardEvents.automate_card_changes(
      card,
      updated,
      changeset,
      {before, assignees || before}
    )

    wait_hooks(card, updated, changeset, opts)
  end

  defp renamed(updated, titled?, named?) do
    # A sub-board is named after its card.
    if titled? do
      from(b in Board, where: b.parent_card_id == ^updated.id)
      |> Repo.update_all(set: [name: Board.name_for_card(updated.title)])
    end

    if named?, do: CardFolders.renamed(updated)
  end

  # What follows from the fields a save changed: mentions, a recurring
  # card's next one, unblocking, incidents and the evidence a completion carried.
  defp changed_hooks(card, updated, %{changeset: changeset, opts: opts}) do
    if Map.has_key?(changeset.changes, :description),
      do:
        Slipdock.Mentions.description_changed(
          updated,
          card.description,
          updated.description,
          opts[:by]
        )

    if Map.has_key?(changeset.changes, :completed),
      do: Slipdock.Recurrence.completion_changed(updated)

    if changeset.changes[:completed] == true,
      do: Boards.Dependencies.unblock_dependents(updated, opts)

    incident_saved(card, updated, opts)

    # Evidence a completion carried is kept as a comment (#1632).
    Slipdock.Verified.saved(card, updated, opts[:by])
  end

  defp assigned_hooks(_updated, %{assignees: nil}), do: :ok

  defp assigned_hooks(updated, %{before: before, assignees: assignees, opts: opts}) do
    # Who an agent put on the card, for a rejection to take off (#1659).
    Slipdock.Verified.assigned(updated, before, assignees, Slipdock.Actor.resolve(opts))

    # Someone new on a snoozed card wakes it (W-1803).
    if Enum.any?(assignees, &(not Enum.member?(before, &1))),
      do: Slipdock.Snooze.activity(updated, opts[:by], :assigned)
  end

  # A % complete a person states is theirs (#1881): an epic's then stops
  # following its subcards, until they clear it. An agent's or a rule's
  # leaves it following them.
  defp percent_by_hand(changeset, opts) do
    actor = actor_or_current(opts)

    case Ecto.Changeset.fetch_change(changeset, :percent_complete) do
      {:ok, nil} ->
        Ecto.Changeset.put_change(changeset, :percent_by_hand, false)

      {:ok, _percent} when actor.kind == "human" ->
        Ecto.Changeset.put_change(changeset, :percent_by_hand, true)

      _ ->
        changeset
    end
  end

  @doc """
  The ids of the people `card` is assigned to, lead first — read from the
  database, so it is right whether or not the set was preloaded.
  """
  def assignee_ids(%Card{id: nil}), do: []

  def assignee_ids(%Card{id: id, assignee_id: lead}) do
    ids = Repo.all(from(a in "card_assignees", where: a.card_id == ^id, select: a.user_id))
    if Enum.member?(ids, lead), do: [lead | List.delete(ids, lead)], else: Enum.sort(ids)
  end

  # Who a write assigns the card to. "assignee_ids" replaces the set, lead
  # first; "add_assignee_ids" and "remove_assignee_ids" edit it, keeping the
  # lead while they are still on it; and a bare "assignee_id" — what every
  # single-person caller sends — replaces it with that one person, which is
  # what it always meant. Returns the new set (nil when the write leaves it
  # alone) and the attrs with the lead in "assignee_id".
  defp assignee_change(card, attrs) do
    ids =
      cond do
        Map.has_key?(attrs, "assignee_ids") ->
          user_ids(attrs["assignee_ids"])

        Map.has_key?(attrs, "add_assignee_ids") or Map.has_key?(attrs, "remove_assignee_ids") ->
          Enum.uniq(assignee_ids(card) ++ user_ids(attrs["add_assignee_ids"])) --
            user_ids(attrs["remove_assignee_ids"])

        Map.has_key?(attrs, "assignee_id") ->
          user_ids(attrs["assignee_id"])

        true ->
          nil
      end

    attrs = Map.drop(attrs, ~w(assignee_ids add_assignee_ids remove_assignee_ids))
    ids = readable_assignees(card, ids)

    case ids do
      nil -> {nil, attrs}
      ids -> {ids, Map.put(attrs, "assignee_id", List.first(ids))}
    end
  end

  defp user_ids(nil), do: []
  defp user_ids(""), do: []

  defp user_ids(ids) when is_list(ids),
    do: ids |> Enum.flat_map(&user_ids/1) |> Enum.uniq()

  defp user_ids(id) when is_integer(id), do: [id]

  defp user_ids(id) when is_binary(id) do
    case Integer.parse(id) do
      {n, ""} -> [n]
      _ -> []
    end
  end

  defp user_ids(_), do: []

  # The card and who is on it are one write: an assignee row that cannot be
  # written takes the card change back with it, rather than leaving half of it.
  defp save_with_assignees(changeset, save, assignees) do
    Repo.transaction(fn ->
      case changeset |> save.() |> put_assignees(assignees) do
        {:ok, card} -> card
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @doc """
  The people `refs` name, as ids, if `by` may put every one of them on
  `target` — a card, a page, or the board a new card is going onto. A ref is
  a user id, an email address, or "me".

  Somebody qualifies when `by` can see them (`Slipdock.Access.visible_user_ids/1`)
  and they can read `target` themselves: a card assigned to a person who cannot
  open it tells them nothing and tells whoever assigned it who has an account.
  Anybody else is `{:error, {:not_found, ref}}`, worded the same whether the
  address belongs to nobody or to somebody out of sight, so the answer is not a
  way of finding out who is on the server.
  """
  @spec resolve_assignees(Card.t() | Board.t() | Slipdock.Wiki.Page.t(), User.t() | nil, [term]) ::
          {:ok, [integer]} | {:error, {:not_found, term}}
  def resolve_assignees(target, by, refs) do
    visible = by |> Slipdock.Access.visible_user_ids() |> MapSet.new()

    refs
    |> List.wrap()
    |> Enum.reduce_while({:ok, []}, fn ref, {:ok, ids} ->
      with %User{} = user <- assignee_ref(ref, by),
           true <- MapSet.member?(visible, user.id),
           true <- can_read_target?(user, target) do
        {:cont, {:ok, ids ++ [user.id]}}
      else
        _ -> {:halt, {:error, {:not_found, ref}}}
      end
    end)
    |> case do
      {:ok, ids} -> {:ok, Enum.uniq(ids)}
      error -> error
    end
  end

  defp assignee_ref(me, %User{} = by) when me in ~w(me myself mine), do: by
  defp assignee_ref(id, _by) when is_integer(id), do: Repo.get(User, id)

  defp assignee_ref(ref, _by) when is_binary(ref) do
    case Integer.parse(ref) do
      {id, ""} -> Repo.get(User, id)
      _ -> Slipdock.Accounts.get_user_by_email(ref)
    end
  end

  defp assignee_ref(_, _), do: nil

  defp can_read_target?(user, %Card{id: nil, board_id: board_id}),
    do: can_read_target?(user, Repo.get!(Board, board_id))

  defp can_read_target?(user, %Card{} = card),
    do: Slipdock.Access.can_read?(Slipdock.Access.card_permission(user, card))

  defp can_read_target?(user, %Board{} = board),
    do: Slipdock.Access.can_read?(Slipdock.Access.board_permission(user, board))

  defp can_read_target?(user, %Slipdock.Wiki.Page{} = page),
    do: Slipdock.Access.can_read?(Slipdock.Access.page_permission(user, page))

  # The backstop under every caller — the API, the board, a swimlane drop, an
  # automation, the model: whoever is newly put on a card has to exist and be
  # able to read it. The callers that answer a person resolve first, with
  # `resolve_assignees/3`, so they can say no; this one drops quietly.
  defp readable_assignees(_card, nil), do: nil

  defp readable_assignees(card, ids) do
    already = assignee_ids(card)
    {kept, added} = Enum.split_with(ids, &Enum.member?(already, &1))
    users = Repo.all(from(u in User, where: u.id in ^added))
    readable = users |> Enum.filter(&can_read_target?(&1, card)) |> MapSet.new(& &1.id)
    Enum.filter(ids, &(Enum.member?(kept, &1) or MapSet.member?(readable, &1)))
  end

  defp put_assignees({:ok, %Card{} = card}, ids) when is_list(ids) do
    from(a in "card_assignees", where: a.card_id == ^card.id) |> Repo.delete_all()
    Repo.insert_all("card_assignees", Enum.map(ids, &%{card_id: card.id, user_id: &1}))
    {:ok, Repo.preload(card, :assignees, force: true)}
  end

  defp put_assignees(result, _ids), do: result

  defp describe_assignees(_card, _before, nil), do: []

  defp describe_assignees(card, before, ids) do
    cond do
      Enum.sort(before) == Enum.sort(ids) -> []
      ids == [] -> ["unassigned “#{card.title}”"]
      true -> ["assigned “#{card.title}” to #{Enum.map_join(ids, ", ", &assignee_name/1)}"]
    end
  end

  defp describe_card_changes(card, changeset) do
    Enum.flat_map(changeset.changes, fn
      {:title, t} ->
        ["renamed “#{card.title}” to “#{t}”"]

      {:completed, true} ->
        ["completed “#{card.title}”"]

      {:completed, false} ->
        ["reopened “#{card.title}”"]

      {:priority, p} ->
        ["set priority of “#{card.title}” to #{p}"]

      {:start_date, nil} ->
        ["cleared start date on “#{card.title}”"]

      {:start_date, d} ->
        ["set start date on “#{card.title}” to #{d}"]

      {:due_date, nil} ->
        ["cleared due date on “#{card.title}”"]

      {:due_date, d} ->
        ["set due date on “#{card.title}” to #{d}"]

      {:percent_complete, nil} ->
        ["cleared % complete on “#{card.title}”"]

      {:percent_complete, p} ->
        ["set “#{card.title}” to #{p}% complete"]

      {:column_id, id} ->
        ["moved “#{card.title}” to #{Repo.get!(Column, id).name}"]

      {:flags, flags} ->
        ["set flags on “#{card.title}” to #{flags_text(flags)}"]

      {:time_spent, m} ->
        [time_text("time spent", card, m, changeset)]

      {:time_estimate, m} ->
        [time_text("estimate", card, m, changeset)]

      # A locked bar changed (by a person: agents are refused) is worth a
      # line of its own (#1622).
      {:bar, _} when not is_nil(card.bar_locked_at) ->
        ["changed the locked bar of “#{card.title}”"]

      {:bar, nil} ->
        ["cleared the bar of “#{card.title}”"]

      {:bar, _} ->
        ["set the bar of “#{card.title}”"]

      _ ->
        []
    end)
  end

  defp time_text(what, card, nil, _changeset), do: "cleared #{what} on “#{card.title}”"

  defp time_text(what, card, minutes, changeset) do
    unit = Ecto.Changeset.get_field(changeset, :time_unit)
    "set #{what} on “#{card.title}” to #{Slipdock.TimeTracking.format(minutes, unit)}"
  end

  @doc """
  Starts the card's timer. Starting one that is already running leaves it
  alone, so two people pressing start do not lose the first one's time.
  """
  def start_timer(%Card{timer_started_at: %DateTime{}} = card), do: {:ok, card}

  def start_timer(%Card{} = card) do
    # Conditional on the timer still being stopped, so two starts racing each
    # other leave the first one's start time in place.
    {count, _} =
      from(c in Card, where: c.id == ^card.id and is_nil(c.timer_started_at))
      |> Repo.update_all(set: [timer_started_at: DateTime.utc_now(:second)])

    updated = Repo.get!(Card, card.id)

    if count == 1 do
      Boards.ActivityLog.log(
        Repo,
        updated.board_id,
        updated.id,
        "card",
        "started the timer on “#{card.title}”"
      )

      Boards.PubSub.broadcast(updated.board_id)
    end

    {:ok, updated}
  end

  @doc """
  Stops the card's timer and adds the minutes it ran to the time spent.
  Stopping one that isn't running does nothing.
  """
  def stop_timer(%Card{timer_started_at: nil} = card), do: {:ok, card}

  def stop_timer(%Card{timer_started_at: since} = card) do
    minutes = Slipdock.TimeTracking.running(card)
    cap = Slipdock.TimeTracking.max_minutes()

    # Conditional on the timer being the one this card was read with: a stop
    # racing another stop (the API and the board at once) finds it already
    # cleared and adds nothing, rather than counting the minutes twice.
    {count, _} =
      from(c in Card,
        where: c.id == ^card.id and c.timer_started_at == ^since,
        update: [
          set: [
            timer_started_at: nil,
            time_spent: fragment("LEAST(COALESCE(?, 0) + ?, ?)", c.time_spent, ^minutes, ^cap)
          ]
        ]
      )
      |> Repo.update_all([])

    updated = Repo.get!(Card, card.id)

    if count == 1 do
      Boards.ActivityLog.log(
        Repo,
        updated.board_id,
        updated.id,
        "card",
        "logged #{Slipdock.TimeTracking.format(minutes, updated.time_unit)} on “#{card.title}” with the timer"
      )

      Boards.PubSub.broadcast(updated.board_id)
    end

    {:ok, updated}
  end

  defp assignee_name(id) do
    case Repo.get(Slipdock.Accounts.User, id) do
      nil -> "nobody"
      user -> Slipdock.Accounts.User.display_name(user)
    end
  end

  defp flags_text([]), do: "none"
  defp flags_text(flags), do: Enum.join(flags, ", ")

  @doc "Turns `flag` on or off. `opts` as for `update_card/3`: who did it."
  def toggle_flag(%Card{} = card, flag, opts \\ []) when is_binary(flag) do
    flags =
      if Enum.member?(card.flags, flag),
        do: List.delete(card.flags, flag),
        else: card.flags ++ [flag]

    update_card(card, %{"flags" => flags}, opts)
  end

  def toggle_completed(%Card{} = card, opts \\ []) do
    update_card(card, %{"completed" => !card.completed}, opts)
  end

  def archive_card(%Card{} = card, opts \\ []) do
    card
    # Archiving puts a card away for good, so any snooze goes with it.
    |> Ecto.Changeset.change(archived_at: DateTime.utc_now(:second), snoozed_until: nil)
    |> Repo.update()
    |> Boards.Shared.tap_ok(fn c ->
      Boards.ActivityLog.log(Repo, c.board_id, c.id, "card", "archived “#{c.title}”")

      if is_nil(card.archived_at) do
        Boards.Moves.record_move(c, "archived", Repo.get(Column, c.column_id), nil, actor(opts))
        CardFolders.archived(c, "archived")
      end

      Slipdock.Recurrence.card_archived(c)
      if is_nil(card.archived_at), do: put_away(card, c, opts)

      Boards.PubSub.broadcast(c.board_id)
      Indexer.enqueue(c)
      Boards.CardEvents.automate(%{type: "card_archived", card: c})
    end)
  end

  # A card archived just now closes its wait and, unless it was done, lets its
  # dependents go.
  defp put_away(card, archived, opts) do
    auto_close_wait(archived, "archived", "the card was archived", opts)
    unless card.completed, do: Boards.Dependencies.unblock_dependents(archived, opts)
  end

  # An archived card does not count against its owner's allowance, so bringing
  # one back is asking for one more — otherwise "archive, add, restore" would
  # go on for ever, trial or no trial.
  def unarchive_card(%Card{} = card, opts \\ []) do
    position = Boards.Shared.next_position(from(c in Card, where: c.column_id == ^card.column_id))

    card
    |> Ecto.Changeset.change(archived_at: nil, position: position)
    |> then(&if(is_nil(card.archived_at), do: &1, else: Quota.enforce(&1, card.board_id)))
    |> Repo.update()
    |> Boards.Shared.tap_ok(fn c ->
      Boards.ActivityLog.log(Repo, c.board_id, c.id, "card", "restored “#{c.title}”")

      if card.archived_at do
        Boards.Moves.record_move(c, "restored", nil, Repo.get(Column, c.column_id), actor(opts))
        CardFolders.archived(c, "restored")
      end

      Boards.PubSub.broadcast(c.board_id)
      Indexer.enqueue(c)
    end)
  end

  def delete_card(%Card{} = card) do
    keys = Boards.Attachments.card_file_keys([card.id])

    Repo.delete(card)
    |> Boards.Shared.tap_ok(fn c ->
      Boards.Attachments.remove_files(keys)
      Indexer.forget(c.id)
      Boards.ActivityLog.log(Repo, c.board_id, nil, "card", "deleted “#{c.title}”")
      Boards.PubSub.broadcast(c.board_id)
    end)
  end

  def list_archived_cards(board_id, q \\ "") do
    from(c in Card,
      where: c.board_id == ^board_id and not is_nil(c.archived_at),
      order_by: [desc: c.archived_at]
    )
    |> archived_matching(q)
    |> Repo.all()
    |> Repo.preload([:tags, :column])
  end

  # `list_cards/2`'s `"q"`: a card's id (`123`, `#123`) or link names that
  # card, as a piece of its title finds it (#2097). No card has id 0.
  defp ref_id(q), do: Boards.Links.card_ref(q) || 0

  # The archive panel's search: a card's id or link names that card, and
  # anything else is a piece of a title.
  defp archived_matching(query, q) do
    q = String.trim(to_string(q))

    cond do
      q == "" ->
        query

      id = Boards.Links.card_ref(q) ->
        where(query, [c], c.id == ^id)

      true ->
        like = "%" <> String.replace(q, ["\\", "%", "_"], &"\\#{&1}") <> "%"
        where(query, [c], ilike(c.title, ^like))
    end
  end

  @doc """
  An archived card on `board_id`, or nil. The id came from a client, so a
  card on anybody else's board is the same as no card at all.
  """
  def get_archived_card(board_id, id) do
    case Boards.Shared.to_id(id) do
      nil ->
        nil

      id ->
        Repo.one(
          from(c in Card,
            where: c.id == ^id and c.board_id == ^board_id and not is_nil(c.archived_at)
          )
        )
    end
  end

  def change_card(%Card{} = card, attrs \\ %{}), do: Card.changeset(card, attrs)

  @doc """
  Moves a card into `to_column_id`, placing it directly before the card
  `before_id` (or at the end when nil), re-packing positions in both the
  source and destination columns.

  `opts` say who moved it (see `Slipdock.Actor`): `:actor`, or `:by` (the
  user), `:via`, `:agent` (a token's label) and `:job_id`. Without them a
  move made while a rule runs is automation's, and any other is unknown.
  """
  def move_card(card_id, to_column_id, before_id \\ nil, opts \\ []) do
    card = Repo.get!(Card, card_id)
    to_column = Repo.get!(Column, to_column_id)

    # A list on another board would pull the card off its own board without
    # any of what `move_card_to_board/2` carries across — and, from a client
    # that sent somebody else's card, onto the sender's board.
    actor = Slipdock.Actor.resolve(opts)

    cond do
      to_column.board_id != card.board_id ->
        {:error, :wrong_board}

      to_column.id == card.column_id ->
        do_move_card(card, to_column, before_id, actor)

      true ->
        # Verified work (#1620): what an agent may start or finish; lanes
        # (#1628): whether its paths overlap a card in progress.
        with :ok <- Slipdock.Verified.check_move(card, to_column, actor),
             :ok <- Slipdock.Lanes.check_move(card, to_column, actor) do
          do_move_card(card, to_column, before_id, actor)
        else
          {:error, message} -> {:error, :unprocessable_entity, message}
        end
    end
  end

  defp do_move_card(%Card{} = card, %Column{} = to_column, before_id, actor) do
    same_column? = to_column.id == card.column_id

    Boards.Columns.reorder({:card, card.id}, card.column_id, to_column.id, before_id)

    unless same_column? do
      Boards.ActivityLog.log(
        Repo,
        card.board_id,
        card.id,
        "card",
        "moved “#{card.title}” to #{to_column.name}"
      )

      from_column = Repo.get!(Column, card.column_id)
      # Before anything the move sets off (a done list completing the card
      # can fire a rule that moves it on), so the ledger keeps their order.
      Boards.Moves.record_move(card, "moved", from_column, to_column, actor)
      apply_column_semantics(Repo.get!(Card, card.id), from_column, to_column)
      Slipdock.Verified.moved(Repo.get!(Card, card.id), to_column)
      # An agent starting it gives it a profile (#1951).
      started(card.id, to_column, actor)
      follow_stand_ins(card, from_column, to_column)
      Boards.Moves.moved(card, from_column, to_column, actor)
      Slipdock.EpicLog.moved(Repo.get!(Card, card.id), from_column, to_column, actor)

      Boards.CardEvents.automate(%{
        type: "card_moved",
        card: Repo.get!(Card, card.id),
        from: from_column,
        to: to_column,
        column: to_column,
        actor: actor
      })
    end

    # The list a card sits in is part of what was embedded about it.
    unless same_column?, do: Indexer.enqueue(card.id)

    # Reordering a list is no event of its own, but it can change which card
    # a rule feeding a runner from the list's top would send next.
    if same_column?, do: Slipdock.Automations.feed_board(card.board_id)

    Boards.PubSub.broadcast(card.board_id)
    :ok
  end

  # What landing in a list means: a "done" list completes the card, leaving
  # one for a to-do or in-progress list reopens it, and a horizon list
  # schedules a card that isn't already inside its range.
  @doc false
  def apply_column_semantics(%Card{} = card, %Column{} = from, %Column{} = to) do
    attrs =
      %{}
      |> Map.merge(
        cond do
          Column.done?(to) and not card.completed ->
            %{"completed" => true}

          Column.done?(from) and Enum.member?(~w(todo doing), to.category) and card.completed ->
            %{"completed" => false}

          true ->
            %{}
        end
      )
      |> Map.merge(horizon_attrs(card, to))

    if attrs == %{}, do: {:ok, card}, else: update_card(card, attrs)
  end

  defp horizon_attrs(%Card{} = card, %Column{} = to) do
    target = to.horizon_to || to.horizon_from

    cond do
      is_nil(target) ->
        %{}

      Column.drifted?(to, card.due_date) or is_nil(card.due_date) ->
        start =
          if card.start_date && Date.compare(card.start_date, target) == :gt,
            do: nil,
            else: card.start_date

        %{
          "due_date" => target,
          "start_date" => start,
          "date_precision" => to.horizon_unit || card.date_precision
        }

      true ->
        %{}
    end
  end

  ## Stand-ins -----------------------------------------------------------------

  @doc """
  Leaves a stand-in for `card` where it was: on its board, in its list,
  before `before` (the item that followed it — see `item_ref/1`), or at the
  end when that has gone. `card` is the card as it was *before* it moved.

  The stand-in is inserted directly rather than through `create_card/3`: it
  is not new work, so it is not checked against the owner's allowance,
  indexed for search, or handed to automations.
  """
  def leave_stand_in(%Card{} = card, before \\ nil) do
    stand_in =
      Repo.insert!(%Card{
        title: card.title,
        board_id: card.board_id,
        column_id: card.column_id,
        position:
          Boards.Shared.next_position(from(c in Card, where: c.column_id == ^card.column_id)),
        stand_in_for_id: card.id
      })

    Boards.Columns.reorder({:card, stand_in.id}, card.column_id, card.column_id, before)

    Boards.ActivityLog.log(
      Repo,
      card.board_id,
      stand_in.id,
      "card",
      "left a stand-in for “#{card.title}”"
    )

    Boards.PubSub.broadcast(card.board_id)
    {:ok, Repo.get!(Card, stand_in.id)}
  end

  @doc "The item after `card` in its list, or nil: where a stand-in for it goes."
  def item_after(%Card{} = card) do
    card.column_id
    |> Boards.Columns.active_items()
    |> Enum.drop_while(&(&1 != {:card, card.id}))
    |> Enum.at(1)
  end

  @doc "The live stand-ins for `card_id`, wherever they are."
  def stand_ins_for(card_id) do
    Repo.all(from(c in Card, where: c.stand_in_for_id == ^card_id and is_nil(c.archived_at)))
  end

  # A card that reaches a done list takes its stand-ins to the done list of
  # their own boards, so the board it was taken from sees it finished where
  # it would look. Mapped by category, never by list name; a board with no
  # done list keeps its stand-in where it is.
  @doc false
  def follow_stand_ins(%Card{} = card, %Column{} = from, %Column{} = to) do
    if Column.done?(to) and not Column.done?(from) and not Card.stand_in?(card) do
      for stand_in <- stand_ins_for(card.id),
          done = done_column(stand_in.board_id),
          done && done.id != stand_in.column_id do
        Boards.Columns.reorder({:card, stand_in.id}, stand_in.column_id, done.id, nil)
        Boards.PubSub.broadcast(stand_in.board_id)
      end
    end

    :ok
  end

  defp done_column(board_id) do
    Repo.one(
      from(c in Column,
        where: c.board_id == ^board_id and c.category == "done",
        order_by: [asc: c.position],
        limit: 1
      )
    )
  end

  # Whoever the opts name, as for a move; failing that, this process's actor
  # (the person behind a LiveView, #2094), as the activity row has; and the
  # person `:by` when neither names a user.
  defp creator(opts) do
    case {actor_or_current(opts), opts[:by]} do
      {%{user_id: nil} = actor, by} when not is_nil(by) ->
        %{actor | user_id: if(is_integer(by), do: by, else: by.id)}

      {actor, _} ->
        actor
    end
  end

  defp actor(opts), do: Slipdock.Actor.resolve(opts)

  # The actor `opts` name, else this process's (`Slipdock.Actor.current/0`).
  defp actor_or_current(opts) do
    case Slipdock.Actor.resolve(opts) do
      %{kind: nil} -> Slipdock.Actor.current()
      actor -> actor
    end
  end

  @doc "The ids of the cards above `card`, the one owning its board first."
  def ancestor_card_ids(%Card{board_id: board_id}) do
    Board
    |> Repo.get!(board_id)
    |> Boards.ancestry()
    |> Enum.map(& &1.card.id)
    |> Enum.reverse()
  end

  # What a change to a card does to its open wait: completing the card
  # closes it, and taking the `waiting` flag off by hand withdraws it (R7,
  # R13). A wait's own flag changes pass `wait_hook: false`.
  defp wait_hooks(before, card, changeset, opts) do
    cond do
      opts[:wait_hook] == false ->
        :ok

      changeset.changes[:completed] == true ->
        auto_close_wait(card, "card_completed", "the card was completed", opts)

      Enum.member?(before.flags, "waiting") and not Enum.member?(card.flags, "waiting") ->
        withdraw_unflagged_wait(card, opts)

      true ->
        :ok
    end
  end

  # The waiting flag taken off by hand withdraws the wait it stood for.
  defp withdraw_unflagged_wait(card, opts) do
    if wait = Boards.Waits.current_wait(card) do
      actor = creator(opts)

      Boards.Waits.close_wait(wait, actor, "withdrawn", flag: false)
      |> Boards.Shared.tap_ok(fn closed ->
        Boards.Comments.add_comment(
          card,
          "#{Boards.ActivityLog.actor_name(actor)} took the waiting flag off, which withdrew the wait " <>
            "“#{closed.needs}”",
          by: Boards.ActivityLog.actor_user(actor)
        )
      end)
    end
  end

  defp auto_close_wait(card, reason, why, opts) do
    if wait = Boards.Waits.current_wait(card) do
      Boards.Waits.close_wait(wait, creator(opts), reason, [])
      |> Boards.Shared.tap_ok(fn closed ->
        Boards.Comments.add_comment(
          Repo.get!(Card, card.id),
          "Wait “#{closed.needs}” closed: #{why}."
        )
      end)
    end
  end

  ## Lookups (#2791): plain reads the web layer makes through this context

  @doc "The card `id` as stored, or nil: none of `get_card/1`'s preloads or rollup."
  def get_card_record(id), do: Repo.get(Card, id)

  @doc "`card` read again from the database, with no associations loaded."
  def reload_card!(%Card{} = card), do: Repo.reload!(card)

  @doc "`card` (or cards) with the board loaded."
  def with_board(card_or_cards), do: Repo.preload(card_or_cards, :board)

  @doc "`card` with its attachments loaded afresh."
  def with_attachments(%Card{} = card), do: Repo.preload(card, :attachments, force: true)

  @doc """
  The cards on `board_id` among `ids` that aren't archived, by id. Ids from
  elsewhere are left out.
  """
  def list_board_cards(board_id, ids) do
    from(c in Card,
      where: c.id in ^ids and c.board_id == ^board_id and is_nil(c.archived_at),
      order_by: [asc: c.id]
    )
    |> Repo.all()
  end

  @doc "The cards among `ids`, with their lists, by id."
  def cards_by_id(ids) do
    from(c in Card, where: c.id in ^Enum.uniq(ids), preload: [:column])
    |> Repo.all()
    |> Map.new(&{&1.id, &1})
  end

  @doc "Each of the cards among `ids` as `id`, `title` and `board_id`, by id."
  def card_briefs(ids) do
    from(c in Card,
      where: c.id in ^ids,
      select: {c.id, %{id: c.id, title: c.title, board_id: c.board_id}}
    )
    |> Repo.all()
    |> Map.new()
  end

  @doc """
  Open cards (not archived, not completed) for a picker, newest first, at
  most `limit`, each with its board. `where` is `{:board, id}` (the board
  and, for a top-level one, its sub-boards) or `{:roots, ids}` (those trees).
  `typed` is digits to match the start of a card number, or text to find in
  titles; empty matches every card.
  """
  def pick_open_cards(where, typed, limit) do
    base =
      from(c in Card,
        join: b in Board,
        on: b.id == c.board_id,
        where: is_nil(c.archived_at) and not c.completed,
        order_by: [desc: c.updated_at, desc: c.id],
        limit: ^limit,
        preload: [board: b]
      )

    base =
      case where do
        {:board, id} -> where(base, [c, b], b.id == ^id or b.root_id == ^id)
        {:roots, ids} -> where(base, [c, b], coalesce(b.root_id, b.id) in ^ids)
      end

    query =
      case Integer.parse(typed) do
        {_, ""} -> where(base, [c], like(fragment("CAST(? AS text)", c.id), ^(typed <> "%")))
        _ when typed == "" -> base
        _ -> where(base, [c], ilike(c.title, ^("%" <> escape_like(typed) <> "%")))
      end

    Repo.all(query)
  end

  defp escape_like(text), do: String.replace(text, ~r/([\\%_])/, "\\\\\\1")

  @doc """
  Every card that isn't archived in the trees of `roots`, sub-boards
  included, with its board, list and assignees.
  """
  def tree_cards(roots) do
    from(c in Card,
      join: b in Board,
      on: b.id == c.board_id,
      where: is_nil(c.archived_at),
      where: coalesce(b.root_id, b.id) in ^roots,
      order_by: [asc: c.board_id, asc: c.position]
    )
    |> Repo.all()
    |> Repo.preload([:board, :column, :assignees])
  end

  @doc """
  Runs `fun` in a transaction. `{:ok, value}` commits and is returned;
  anything else rolls the transaction back and comes back as `{:error, it}`.
  """
  def transact(fun) when is_function(fun, 0) do
    Repo.transaction(fn ->
      case fun.() do
        {:ok, value} -> value
        other -> Repo.rollback(other)
      end
    end)
  end
end
