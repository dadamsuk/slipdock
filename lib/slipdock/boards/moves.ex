defmodule Slipdock.Boards.Moves do
  @moduledoc """
  Moving a card, with its subcards, to another board, and the movement
  ledger (`Boards.CardMove`) that records when a card entered each list.
  """

  import Ecto.Query, warn: false

  alias Slipdock.Boards
  alias Slipdock.Boards.Attachment
  alias Slipdock.Boards.Board
  alias Slipdock.Boards.Card
  alias Slipdock.Boards.CardMove
  alias Slipdock.Boards.Column
  alias Slipdock.Boards.FieldDefinition
  alias Slipdock.Boards.FieldValue
  alias Slipdock.Boards.Milestone
  alias Slipdock.Boards.Tag
  alias Slipdock.Quota
  alias Slipdock.Repo
  alias Slipdock.Search.Indexer

  defp stand_in_on(card_id, board_id) do
    Repo.one(
      from(c in Card,
        where:
          c.stand_in_for_id == ^card_id and c.board_id == ^board_id and is_nil(c.archived_at),
        order_by: [asc: c.id],
        limit: 1
      )
    )
  end

  ## Moving a card to another board -------------------------------------------

  @doc """
  Moves `card` to a list on a different board, with everything beneath it.

  A card is not only a row in a list: it may hold subcards on a board of its
  own, tags, values for the board's custom fields and a pinned milestone —
  and all of those belong to the *root* board of a tree, not to the board the
  card sits on. Which is why this is not `move_card/3` with a wider `where`:

    * the boards under the card are re-rooted, so their tags and fields keep
      resolving after the move;
    * tags travel by name — matched on the destination tree, created there
      when they are new — for the card and everything under it, because a
      subcard's tags came from the old root too;
    * custom field values travel where the destination tree has a field with
      the same key *and* kind, and are dropped where it does not, because a
      number cannot be stored in a date;
    * a milestone pinned to a moved card is unpinned: it is a date on the old
      tree's roadmap and stays there.

  Moving inside one tree (a subcard promoted to its root board, say) skips
  all of that: the tree already shares its tags, fields and milestones.

  Returns `{:ok, summary}` — the moved card and what it cost on the way — or
  `{:error, message}`.
  """
  def move_card_to_board(%Card{} = card, %Column{} = to_column, opts \\ []) do
    cond do
      not is_nil(card.archived_at) ->
        {:error, "Restore the card before moving it."}

      Card.stand_in?(card) ->
        {:error, "A stand-in stays on its own board — move the card it stands for instead."}

      to_column.board_id == card.board_id ->
        case Boards.Cards.move_card(card.id, to_column.id, nil, opts) do
          :ok -> {:ok, empty_move_summary(Repo.get!(Card, card.id))}
          {:error, _status, message} -> {:error, message}
          {:error, _} = refused -> refused
        end

      Enum.member?(subtree_board_ids(card.id), to_column.board_id) ->
        {:error, "A card can't be moved into its own subcards."}

      true ->
        actor = Slipdock.Actor.resolve(opts)

        with :ok <- reopen_across_boards(card, to_column, actor),
             :ok <- room_for_move(card, to_column),
             do: do_move_card_to_board(card, to_column, actor)
    end
  end

  # Done stays done on another board too (#1851): an agent can't take a
  # completed card out of a done list into one that isn't. Judged against
  # the list it would land in, which is a kept stand-in's, if there is one.
  defp reopen_across_boards(%Card{} = card, %Column{} = to_column, actor) do
    landing =
      case stand_in_on(card.id, to_column.board_id) do
        nil -> to_column
        slot -> Repo.get!(Column, slot.column_id)
      end

    case Slipdock.Verified.reopen_move_message(card, landing, actor) do
      nil -> :ok
      message -> {:error, message}
    end
  end

  # A card that changes owner takes everything under it into the new owner's
  # count: its live subcards, the pages on its sub-boards and the files on
  # both. Checked against the destination, or a free account could make cards
  # on somebody's paid board and carry them home. Within one owner's boards
  # nothing changes hands, so nothing is checked.
  defp room_for_move(%Card{} = card, %Column{} = to_column) do
    if Quota.owner_id_of(card.board_id) == Quota.owner_id_of(to_column.board_id) do
      :ok
    else
      board_ids = subtree_board_ids(card.id)
      card_ids = [card.id | subtree_card_ids(board_ids)]

      cards =
        Repo.aggregate(
          from(c in Card,
            where: c.id in ^card_ids and is_nil(c.archived_at) and is_nil(c.stand_in_for_id)
          ),
          :count
        )

      pages =
        Repo.aggregate(
          from(p in Slipdock.Wiki.Page,
            where: p.board_id in ^board_ids and is_nil(p.archived_at)
          ),
          :count
        )

      {files, bytes} =
        Repo.one(
          from(a in Attachment,
            left_join: p in Slipdock.Wiki.Page,
            on: p.id == a.page_id,
            where: a.card_id in ^card_ids or p.board_id in ^board_ids,
            select: {count(a.id), coalesce(sum(a.size), 0)}
          )
        )

      Quota.refusal(to_column, items: cards + pages + files, storage: bytes)
    end
  end

  defp do_move_card_to_board(%Card{} = card, %Column{} = to_column, actor) do
    # Back to a board that kept a stand-in for it: the card takes the
    # stand-in's slot, and the stand-in goes.
    slot = stand_in_on(card.id, to_column.board_id)
    to_column = if slot, do: Repo.get!(Column, slot.column_id), else: to_column
    from_board = Repo.get!(Board, card.board_id)
    to_board = Repo.get!(Board, to_column.board_id)

    move = %{
      slot: slot,
      from_column: Repo.get!(Column, card.column_id),
      to_column: to_column,
      from_board: from_board,
      to_board: to_board,
      from_root: Board.root_id(from_board),
      to_root: Board.root_id(to_board),
      board_ids: subtree_board_ids(card.id)
    }

    {:ok, summary} = Repo.transaction(fn -> move_across(card, move, actor) end)

    moved = Repo.get!(Card, card.id)
    log_move_across(card, moved, move)
    moved_across(moved, move, actor)
    {:ok, %{summary | card: Repo.get!(Card, moved.id)}}
  end

  # The move itself, inside its transaction: out of the old list, into the
  # new one (or the stand-in's slot), the sub-boards re-rooted and the tree's
  # tags, fields and milestones carried over.
  defp move_across(%Card{} = card, move, actor) do
    %{slot: slot, to_column: to_column, from_root: from_root, to_root: to_root} = move

    Boards.Columns.repack(
      List.delete(Boards.Columns.active_items(card.column_id), {:card, card.id}),
      card.column_id
    )

    position =
      if slot,
        do: slot.position,
        else: Boards.Shared.next_position(from(c in Card, where: c.column_id == ^to_column.id))

    if slot, do: Repo.delete!(slot)

    moved =
      card
      |> Ecto.Changeset.change(
        board_id: move.to_board.id,
        column_id: to_column.id,
        position: position
      )
      |> Repo.update!()

    # One row for the card, carrying both boards; its subcards ride
    # along without changing list, so they get none.
    record_move(moved, "moved", move.from_column, to_column, actor)

    if from_root == to_root do
      empty_move_summary(moved)
    else
      reroot_subtree(moved, move)
    end
  end

  # Into another tree: the boards under the card follow it, and what the old
  # tree's root owned is matched on the new one.
  defp reroot_subtree(%Card{} = moved, %{board_ids: board_ids, to_root: to_root}) do
    if board_ids != [] do
      to_owner = Repo.one(from(b in Board, where: b.id == ^to_root, select: b.owner_id))

      from(b in Board, where: b.id in ^board_ids)
      # The owner too: a sub-board's own `owner_id` is what makes somebody
      # its owner, and the mover keeping that after the destination's
      # owner has revoked their access would be a door left open.
      |> Repo.update_all(set: [root_id: to_root, owner_id: to_owner])
    end

    card_ids = [moved.id | subtree_card_ids(board_ids)]

    %{
      card: moved,
      tags_created: remap_tags(card_ids, to_root),
      fields_dropped: remap_field_values(card_ids, to_root),
      milestones_unpinned: unpin_milestones(card_ids)
    }
  end

  defp log_move_across(%Card{} = card, %Card{} = moved, move) do
    %{from_board: from_board, to_board: to_board} = move

    Boards.ActivityLog.log(
      Repo,
      from_board.id,
      nil,
      "card",
      "moved “#{card.title}” to #{to_board.name} › #{move.to_column.name}"
    )

    Boards.ActivityLog.log(
      Repo,
      to_board.id,
      moved.id,
      "card",
      "moved “#{card.title}” in from #{from_board.name} › #{move.from_column.name}"
    )
  end

  # What follows a move across boards, once it is in: the lists' semantics,
  # stand-ins, search, the board's rules and the broadcast to both boards.
  defp moved_across(%Card{} = moved, move, actor) do
    %{from_column: from_column, to_column: to_column} = move

    Boards.Cards.apply_column_semantics(moved, from_column, to_column)
    Boards.Cards.follow_stand_ins(moved, from_column, to_column)
    moved(moved, from_column, to_column, actor)

    # The board a chunk records is what decides who may search it up, so the
    # moved card and everything beneath it are corrected inline rather than
    # waiting in the queue — then queued, to catch up the text as well.
    Slipdock.Search.relocate_card(moved.id)
    Indexer.enqueue_all(Slipdock.Search.subtree_card_ids(moved.id))

    Boards.CardEvents.automate(%{
      type: "card_moved",
      card: Repo.get!(Card, moved.id),
      from: from_column,
      to: to_column,
      column: to_column,
      actor: actor
    })

    Boards.PubSub.broadcast(move.from_board.id)
    Boards.PubSub.broadcast(move.to_board.id)
  end

  # Every change of a card's list passes here, once, with who made it — before
  # the rules it sets off, so a rule's own move comes after it.
  @doc false
  def moved(%Card{} = card, %Column{} = from, %Column{} = to, actor) do
    :telemetry.execute([:slipdock, :card, :moved], %{count: 1}, %{
      card_id: card.id,
      from_column_id: from.id,
      to_column_id: to.id,
      actor: actor
    })
  end

  @doc """
  Writes one row of the movement ledger (`Slipdock.Boards.CardMove`): `kind`
  happened to `card`, from list `from` to list `to` (either nil where it does
  not apply), by `actor` (a `Slipdock.Actor`). Called from this module's
  move, create, archive and restore paths, and by the portable import, which
  inserts cards itself. A stand-in never gets a row.
  """
  def record_move(%Card{stand_in_for_id: id}, _kind, _from, _to, _actor) when not is_nil(id),
    do: :ok

  def record_move(%Card{} = card, kind, from, to, actor)
      when kind in ~w(created moved archived restored) do
    actor = actor || Slipdock.Actor.unknown()

    %CardMove{
      card_id: card.id,
      kind: kind,
      board_id: (to || from || card).board_id,
      actor_kind: actor[:kind],
      via: actor[:via],
      user_id: actor[:user_id],
      agent: actor[:agent],
      job_id: known_job(actor[:job_id])
    }
    |> struct!(from_fields(from))
    |> struct!(to_fields(to))
    |> Repo.insert!()

    recount_epic(kind, card)
    :ok
  end

  # The list a card left and the one it went into, either of which may be nil.
  defp from_fields(nil),
    do: [from_board_id: nil, from_column_id: nil, from_column_name: nil, from_category: nil]

  defp from_fields(from) do
    [
      from_board_id: from.board_id,
      from_column_id: from.id,
      from_column_name: from.name,
      from_category: from.category
    ]
  end

  defp to_fields(nil), do: [to_column_id: nil, to_column_name: nil, to_category: nil]

  defp to_fields(to), do: [to_column_id: to.id, to_column_name: to.name, to_category: to.category]

  # A subcard added, archived or restored changes its epic's count (#1881).
  defp recount_epic("moved", _card), do: :ok
  defp recount_epic(_kind, card), do: Slipdock.EpicLog.recount(card)

  # A job id can come from a request header, so it is only kept when it
  # names a job, rather than failing the move on the foreign key.
  defp known_job(nil), do: nil

  defp known_job(id) do
    if Repo.exists?(from(j in Slipdock.Runners.Job, where: j.id == ^id)), do: id
  end

  @doc """
  When each open card on `board` (a board or its id) came into the list it is
  in: card id => the time of its latest ledger row putting it in a list
  (created, moved or restored). A card whose latest such row is not into its
  current list — a move the backfill couldn't read — is left out: its time
  there is unknown. One query for the whole board.
  """
  def list_entered_at(%Board{id: id}), do: list_entered_at(id)

  def list_entered_at(board_id) when is_integer(board_id) do
    latest =
      from(m in CardMove,
        join: c in Card,
        on: c.id == m.card_id,
        where: c.board_id == ^board_id and m.kind in ^CardMove.entry_kinds(),
        distinct: m.card_id,
        order_by: [asc: m.card_id, desc: m.inserted_at, desc: m.id],
        select: %{card_id: m.card_id, to_column_id: m.to_column_id, at: m.inserted_at}
      )

    from(c in Card,
      join: m in subquery(latest),
      on: m.card_id == c.id and m.to_column_id == c.column_id,
      where: c.board_id == ^board_id and is_nil(c.archived_at),
      select: {c.id, m.at}
    )
    |> Repo.all()
    |> Map.new()
  end

  defp empty_move_summary(card),
    do: %{card: card, tags_created: 0, fields_dropped: 0, milestones_unpinned: 0}

  @doc "The ids of every board beneath `card_id`, however deep."
  def subtree_board_ids(card_id) do
    case Repo.all(from(b in Board, where: b.parent_card_id == ^card_id, select: b.id)) do
      [] ->
        []

      ids ->
        deeper = ids |> subtree_card_ids() |> Enum.flat_map(&subtree_board_ids/1)
        ids ++ deeper
    end
  end

  defp subtree_card_ids([]), do: []

  defp subtree_card_ids(board_ids),
    do: Repo.all(from(c in Card, where: c.board_id in ^board_ids, select: c.id))

  # Tags belong to a tree, so a moved card's tags are the wrong rows on the
  # far side. Match on the name, case aside; make the ones that are new.
  # The tag of that name on the new tree, made there if it has none; `n`
  # counts the ones made.
  defp ensure_tag(tag, {n, acc}, to_root) do
    key = String.downcase(tag.name)

    case acc[key] do
      nil ->
        {:ok, made} =
          %Tag{}
          |> Tag.changeset(%{
            "name" => tag.name,
            "color" => tag.color,
            "board_id" => to_root
          })
          |> Repo.insert()

        {n + 1, Map.put(acc, key, made)}

      _ ->
        {n, acc}
    end
  end

  defp remap_tags(card_ids, to_root) do
    joins =
      Repo.all(
        from(ct in "card_tags", where: ct.card_id in ^card_ids, select: {ct.card_id, ct.tag_id})
      )

    if joins == [] do
      0
    else
      old = Repo.all(from(t in Tag, where: t.id in ^Enum.map(joins, &elem(&1, 1))))
      by_id = Map.new(old, &{&1.id, &1})
      existing = to_root |> Boards.Tags.list_tags() |> Map.new(&{String.downcase(&1.name), &1})

      {created, by_name} = Enum.reduce(old, {0, existing}, &ensure_tag(&1, &2, to_root))

      Repo.delete_all(from(ct in "card_tags", where: ct.card_id in ^card_ids))

      rows =
        for {card_id, tag_id} <- joins,
            tag = by_id[tag_id],
            replacement = by_name[String.downcase(tag.name)],
            uniq: true,
            do: %{card_id: card_id, tag_id: replacement.id}

      Repo.insert_all("card_tags", rows)
      created
    end
  end

  # Field definitions belong to a tree too. A value survives where the
  # destination has a field with the same key and kind; anything else would
  # be putting a number in a date.
  defp remap_field_values(card_ids, to_root) do
    values =
      Repo.all(
        from(v in FieldValue,
          join: f in FieldDefinition,
          on: f.id == v.field_id,
          where: v.card_id in ^card_ids,
          select: {v, f.key, f.kind}
        )
      )

    targets =
      to_root
      |> Slipdock.Fields.list_fields()
      |> Map.new(&{{&1.key, &1.kind}, &1})

    Enum.reduce(values, 0, fn {value, key, kind}, dropped ->
      case targets[{key, kind}] do
        nil ->
          Repo.delete(value)
          dropped + 1

        field ->
          value |> Ecto.Changeset.change(field_id: field.id) |> Repo.update!()
          dropped
      end
    end)
  end

  # A milestone is a date on the old tree's roadmap; the card is leaving it.
  defp unpin_milestones(card_ids) do
    {n, _} =
      from(m in Milestone, where: m.card_id in ^card_ids) |> Repo.update_all(set: [card_id: nil])

    n
  end
end
