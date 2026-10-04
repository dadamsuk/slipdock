defmodule Slipdock.Rollup do
  @moduledoc """
  Rolls facts up a board tree so a card summarises everything beneath it.

  A card's sub-board holds its subcards, and those can have sub-boards of
  their own, so a root board is the top of a tree. For every card in the
  tree this module derives, from the card's descendants:

    * `total` / `done` – leaf cards beneath it (a card with no subcards is
      one leaf, done when completed); a parent's progress is the progress of
      its leaves, whatever its own completed flag says
    * `start` / `due` – the card's effective dates: its own, or when it has
      none, the earliest start / latest due of its children (recursively).
      `start_derived?` / `due_derived?` say which
    * `derived_start` / `derived_due` – the children's range alone, so a
      planned date can be compared with what the work beneath implies
    * `start_slip` – days the children *begin* after the card's own start date
      (0 if the card has no start of its own, or they begin on time)
    * `due_slip` – days the children *end* after the card's own due date (0 if
      the card has no due date of its own, or they end on time)
    * `blocked` / `overdue` – true when the card or any descendant is
    * `health` – `:done`, `:blocked`, `:late` (past a date, or the children
      run past one), `:ok`,
      or `:dropped` when the card sits in a "dropped" list (it then counts
      for nothing: a dropped leaf is 0 of 0)
    * `stated` – the card's own latest stated health (see
      `Slipdock.Boards.StatusUpdate`), or nil
    * `sums` – for each custom field flagged to roll up (by field id), the
      total of its values over the leaves beneath, and the part that is done
    * `depth` – 0 for a leaf, else one more than the deepest child
    * `children` – the number of direct subcards

  `build/2` loads a tree and computes everything; `compute/3` is the pure
  part. The result decorates cards through their virtual `rollup` field (see
  `decorate/2`), so components need only the card.
  """

  import Ecto.Query

  alias Slipdock.Boards.{Board, Card}
  alias Slipdock.Repo

  @type stats :: %{
          total: non_neg_integer,
          done: non_neg_integer,
          start: Date.t() | nil,
          due: Date.t() | nil,
          start_derived?: boolean,
          due_derived?: boolean,
          derived_start: Date.t() | nil,
          derived_due: Date.t() | nil,
          start_slip: non_neg_integer,
          due_slip: non_neg_integer,
          blocked: boolean,
          overdue: boolean,
          health: :done | :blocked | :late | :ok | :dropped,
          stated: String.t() | nil,
          sums: %{integer => %{total: float, done: float}},
          depth: non_neg_integer,
          children: non_neg_integer
        }

  defstruct root_id: nil,
            boards: %{},
            cards: %{},
            children: %{},
            sub_board: %{},
            stats: %{},
            today: nil

  @type t :: %__MODULE__{
          root_id: integer,
          boards: %{integer => Board.t()},
          cards: %{integer => Card.t()},
          children: %{integer => [Card.t()]},
          sub_board: %{integer => integer},
          stats: %{integer => stats},
          today: Date.t()
        }

  @card_fields [
    :id,
    :title,
    :description,
    :completed,
    :archived_at,
    :board_id,
    :column_id,
    :position,
    :priority,
    :flags,
    :color,
    :start_date,
    :due_date,
    :assignee_id,
    :inserted_at,
    :updated_at
  ]

  ## Loading ------------------------------------------------------------------

  @doc "Loads and rolls up the tree rooted at `root_id`."
  @spec build(integer | Board.t(), Date.t()) :: t
  def build(root, today \\ Date.utc_today())
  def build(%Board{} = board, today), do: build(Board.root_id(board), today)

  def build(root_id, today) when is_integer(root_id) do
    {boards, cards, open_blocked, stated, values} = load(root_id)

    compute(boards, cards, today,
      root_id: root_id,
      blocked: open_blocked,
      stated: stated,
      values: values,
      dropped: dropped_ids(boards, cards)
    )
  end

  # The ids of cards sitting in a "dropped" list.
  defp dropped_ids(boards, cards) do
    dropped_cols =
      for b <- boards,
          is_list(b.columns),
          c <- b.columns,
          c.category == "dropped",
          into: MapSet.new(),
          do: c.id

    for c <- cards, MapSet.member?(dropped_cols, c.column_id), into: MapSet.new(), do: c.id
  end

  # Every board in the tree with its lists, every active card on them, and
  # the ids of cards that an open card still blocks: three queries (plus one
  # for tags), whatever the depth.
  defp load(root_id) do
    boards =
      from(b in Board,
        where: b.id == ^root_id or b.root_id == ^root_id,
        preload: [columns: ^from(c in Slipdock.Boards.Column, order_by: c.position)]
      )
      |> Repo.all()

    board_ids = Enum.map(boards, & &1.id)

    cards =
      from(c in Card,
        where: c.board_id in ^board_ids and is_nil(c.archived_at),
        order_by: [asc: c.position],
        select: ^@card_fields,
        preload: [:tags, :assignee, :assignees]
      )
      |> Repo.all()

    card_ids = Enum.map(cards, & &1.id)

    # These cards are loaded light, so they answer "is this a document?" here
    # rather than from attachments they haven't got (see `Slipdock.Kinds`).
    documents = document_ids(card_ids)
    cards = Enum.map(cards, &%{&1 | document: MapSet.member?(documents, &1.id)})

    open_blocked =
      from(d in "card_dependencies",
        join: c in Card,
        on: c.id == d.blocker_id,
        where: d.blocked_id in ^card_ids and c.completed == false and is_nil(c.archived_at),
        select: d.blocked_id,
        distinct: true
      )
      |> Repo.all()
      |> MapSet.new()

    sum_fields =
      from(f in Slipdock.Boards.FieldDefinition,
        where: f.board_id == ^root_id and f.sum == true and f.kind in ~w(number rating),
        select: f.id
      )
      |> Repo.all()

    # card id => %{field id => number}, for the fields that roll up.
    values =
      if sum_fields == [] do
        %{}
      else
        from(v in Slipdock.Boards.FieldValue,
          where: v.card_id in ^card_ids and v.field_id in ^sum_fields and not is_nil(v.number),
          select: {v.card_id, v.field_id, v.number}
        )
        |> Repo.all()
        |> Enum.group_by(&elem(&1, 0), fn {_, f, n} -> {f, n} end)
        |> Map.new(fn {card_id, pairs} -> {card_id, Map.new(pairs)} end)
      end

    {boards, cards, open_blocked, Slipdock.Boards.latest_stated_health(card_ids), values}
  end

  # The ids of the cards that are documents: something attached, nothing
  # written, nothing to tick off and no work hanging beneath
  # (`Slipdock.Kinds.document?/1`, in SQL).
  defp document_ids([]), do: MapSet.new()

  defp document_ids(card_ids) do
    from(a in Slipdock.Boards.Attachment,
      join: c in Card,
      as: :card,
      on: c.id == a.card_id,
      where:
        a.card_id in ^card_ids and
          fragment("coalesce(trim(?), '') = ''", c.description) and
          not exists(
            from(i in Slipdock.Boards.ChecklistItem, where: i.card_id == parent_as(:card).id)
          ) and
          not exists(
            from(sc in Card,
              join: b in Board,
              on: b.id == sc.board_id,
              where: b.parent_card_id == parent_as(:card).id and is_nil(sc.archived_at)
            )
          ),
      select: a.card_id,
      distinct: true
    )
    |> Repo.all()
    |> MapSet.new()
  end

  ## Computing ------------------------------------------------------------------

  @doc """
  Rolls up `cards` (active, from every board in `boards`) as of `today`.

  Options: `:root_id` (else the board without a parent card), `:blocked`
  (a set of ids of cards that an open card blocks; else cards are taken as
  blocked when they say so through `Slipdock.Boards.Card.blocked?/1`),
  `:dropped` (a set of ids of cards in dropped lists; else derived from the
  boards' lists) and `:stated` (a map of card id to stated health).
  """
  @spec compute([Board.t()], [Card.t()], Date.t(), keyword) :: t
  def compute(boards, cards, today \\ Date.utc_today(), opts \\ []) do
    root_id =
      opts[:root_id] ||
        case Enum.find(boards, &is_nil(&1.parent_card_id)) do
          nil -> nil
          board -> board.id
        end

    blocked_ids = opts[:blocked]
    dropped = opts[:dropped] || dropped_ids(boards, cards)
    stated = opts[:stated] || %{}
    values = opts[:values] || %{}
    board_map = Map.new(boards, &{&1.id, &1})
    sub_board = for b <- boards, b.parent_card_id, into: %{}, do: {b.parent_card_id, b.id}

    # Cards per board in board order: list position, then card position.
    by_board =
      cards
      |> Enum.group_by(& &1.board_id)
      |> Map.new(fn {board_id, cs} ->
        col_pos =
          case board_map[board_id] do
            %{columns: cols} when is_list(cols) -> Map.new(cols, &{&1.id, &1.position})
            _ -> %{}
          end

        {board_id, Enum.sort_by(cs, &{Map.get(col_pos, &1.column_id, 0), &1.position})}
      end)

    children =
      Map.new(cards, fn card ->
        {card.id, Map.get(by_board, sub_board[card.id], [])}
      end)

    blocked? = fn card ->
      if blocked_ids, do: MapSet.member?(blocked_ids, card.id), else: Card.blocked?(card)
    end

    ctx = %{
      children: children,
      blocked?: blocked?,
      dropped: dropped,
      stated: stated,
      values: values,
      today: today
    }

    stats =
      Enum.reduce(cards, %{}, fn card, acc ->
        if Map.has_key?(acc, card.id),
          do: acc,
          else: elem(compute_card(card, ctx, acc), 1)
      end)

    %__MODULE__{
      root_id: root_id,
      boards: board_map,
      cards: Map.new(cards, &{&1.id, &1}),
      children: children,
      sub_board: sub_board,
      stats: stats,
      today: today
    }
  end

  defp compute_card(card, ctx, acc) do
    case Map.fetch(acc, card.id) do
      {:ok, stats} ->
        {stats, acc}

      :error ->
        kids = Map.get(ctx.children, card.id, [])
        {kid_stats, acc} = Enum.map_reduce(kids, acc, &compute_card(&1, ctx, &2))
        dropped? = MapSet.member?(ctx.dropped, card.id)

        stats =
          card
          |> card_stats(kid_stats, ctx.blocked?.(card), ctx.today, dropped?)
          |> Map.put(:stated, Map.get(ctx.stated, card.id))
          |> Map.put(:sums, sums(card, kid_stats, Map.get(ctx.values, card.id, %{}), dropped?))

        {stats, Map.put(acc, card.id, stats)}
    end
  end

  # A dropped card counts for nothing, whatever lies beneath it.
  defp card_stats(card, _kids, _blocked, _today, true) do
    %{
      total: 0,
      done: 0,
      start: card.start_date,
      due: card.due_date,
      start_derived?: false,
      due_derived?: false,
      derived_start: nil,
      derived_due: nil,
      start_slip: 0,
      due_slip: 0,
      blocked: false,
      overdue: false,
      health: :dropped,
      depth: 0,
      children: 0
    }
  end

  defp card_stats(card, [], blocked, today, false) do
    overdue = overdue?(card, today)

    %{
      total: 1,
      done: if(card.completed, do: 1, else: 0),
      start: card.start_date,
      due: card.due_date,
      start_derived?: false,
      due_derived?: false,
      derived_start: nil,
      derived_due: nil,
      start_slip: 0,
      due_slip: 0,
      blocked: blocked,
      overdue: overdue,
      health: health(card, blocked, overdue, 0, 1, if(card.completed, do: 1, else: 0)),
      depth: 0,
      children: 0
    }
  end

  defp card_stats(card, kids, blocked, today, false) do
    total = kids |> Enum.map(& &1.total) |> Enum.sum()
    done = kids |> Enum.map(& &1.done) |> Enum.sum()
    derived_start = kids |> Enum.map(&starts_on/1) |> min_date()
    derived_due = kids |> Enum.map(&ends_on/1) |> max_date()

    # Measured against the card's *own* dates, never a derived one: a card with
    # no start date of its own promises nothing about when work begins, so
    # there is nothing for its children to be past.
    start_slip = days_past(derived_start, card.start_date)
    due_slip = days_past(derived_due, card.due_date)

    blocked = blocked or Enum.any?(kids, & &1.blocked)
    overdue = overdue?(card, today) or Enum.any?(kids, & &1.overdue)

    %{
      total: total,
      done: done,
      start: card.start_date || derived_start,
      due: card.due_date || derived_due,
      start_derived?: is_nil(card.start_date) and not is_nil(derived_start),
      due_derived?: is_nil(card.due_date) and not is_nil(derived_due),
      derived_start: derived_start,
      derived_due: derived_due,
      start_slip: start_slip,
      due_slip: due_slip,
      blocked: blocked,
      overdue: overdue,
      health: health(card, blocked, overdue, max(start_slip, due_slip), total, done),
      depth: 1 + (kids |> Enum.map(& &1.depth) |> Enum.max()),
      children: length(kids)
    }
  end

  # How far `derived` falls after `own`, or 0 when it does not (or when the
  # card has no date of its own to be measured against).
  defp days_past(nil, _own), do: 0
  defp days_past(_derived, nil), do: 0

  defp days_past(derived, own) do
    if Date.compare(derived, own) == :gt, do: Date.diff(derived, own), else: 0
  end

  # A leaf contributes its own values; a parent the sum of its leaves'. A
  # parent's own values are ignored, as its progress is.
  defp sums(_card, _kids, _own, true), do: %{}

  defp sums(card, [], own, false) do
    Map.new(own, fn {field_id, n} ->
      {field_id, %{total: n * 1.0, done: if(card.completed, do: n * 1.0, else: 0.0)}}
    end)
  end

  defp sums(_card, kids, _own, false) do
    Enum.reduce(kids, %{}, fn kid, acc ->
      Enum.reduce(kid.sums || %{}, acc, fn {field_id, %{total: t, done: d}}, acc ->
        Map.update(acc, field_id, %{total: t, done: d}, fn %{total: t0, done: d0} ->
          %{total: t0 + t, done: d0 + d}
        end)
      end)
    end)
  end

  defp overdue?(%{completed: true}, _today), do: false
  defp overdue?(%{due_date: %Date{} = due}, today), do: Date.compare(due, today) == :lt
  defp overdue?(_, _), do: false

  defp health(card, blocked, overdue, slip, total, done) do
    cond do
      card.completed or (total > 0 and done == total) -> :done
      total == 0 -> :dropped
      blocked -> :blocked
      overdue or slip > 0 -> :late
      true -> :ok
    end
  end

  # The range a card's stats occupy, mirroring Card.starts_on/ends_on.
  defp starts_on(%{start: nil, due: due}), do: due
  defp starts_on(%{start: start}), do: start
  defp ends_on(%{due: nil, start: start}), do: start
  defp ends_on(%{due: due}), do: due

  defp min_date(dates), do: dates |> Enum.reject(&is_nil/1) |> Enum.min(Date, fn -> nil end)
  defp max_date(dates), do: dates |> Enum.reject(&is_nil/1) |> Enum.max(Date, fn -> nil end)

  ## Reading -------------------------------------------------------------------

  @doc "The stats of a card (by id or struct), or nil when it isn't in the tree."
  def stats(%__MODULE__{stats: stats}, %{id: id}), do: Map.get(stats, id)
  def stats(%__MODULE__{stats: stats}, id), do: Map.get(stats, id)
  def stats(nil, _), do: nil

  @doc "A card's direct subcards (light structs, board order), each decorated."
  def children(%__MODULE__{} = rollup, %{id: id}), do: children(rollup, id)

  def children(%__MODULE__{} = rollup, id) do
    rollup.children |> Map.get(id, []) |> Enum.map(&put_stats(&1, rollup))
  end

  @doc "The cards on a board of the tree (light structs, board order), decorated."
  def board_cards(%__MODULE__{} = rollup, board_id) do
    rollup.cards
    |> Map.values()
    |> Enum.filter(&(&1.board_id == board_id))
    |> sort_board_order(rollup.boards[board_id])
    |> Enum.map(&put_stats(&1, rollup))
  end

  defp sort_board_order(cards, %{columns: cols}) when is_list(cols) do
    col_pos = Map.new(cols, &{&1.id, &1.position})
    Enum.sort_by(cards, &{Map.get(col_pos, &1.column_id, 0), &1.position})
  end

  defp sort_board_order(cards, _), do: Enum.sort_by(cards, & &1.position)

  @doc "The ids of every board in the tree."
  def board_ids(%__MODULE__{boards: boards}), do: Map.keys(boards)

  @doc "Whether a card belongs to a board of the tree."
  def member?(%__MODULE__{boards: boards}, %{board_id: board_id}),
    do: Map.has_key?(boards, board_id)

  def member?(_, _), do: false

  @doc "The board of the tree with that id, if any (with its lists)."
  def board(%__MODULE__{boards: boards}, id), do: Map.get(boards, id)

  @doc """
  The nested subtree beneath the cards of `board_id`, to `depth` levels
  (`:all` for no limit). Each node is `%{card, stats, children, level}`;
  `level` counts from 0 on the given board. Cards are decorated.
  """
  def tree(%__MODULE__{} = rollup, board_id, depth \\ :all) do
    rollup |> board_cards(board_id) |> nodes(rollup, 0, depth)
  end

  defp nodes(cards, rollup, level, depth) do
    Enum.map(cards, fn card ->
      kids =
        if depth == :all or level + 1 < depth,
          do: rollup |> children(card) |> nodes(rollup, level + 1, depth),
          else: []

      %{card: card, stats: card.rollup, children: kids, level: level}
    end)
  end

  @doc "The number of levels beneath the cards of `board_id` (1 when none has subcards)."
  def levels(%__MODULE__{} = rollup, board_id) do
    rollup
    |> board_cards(board_id)
    |> Enum.map(&((&1.rollup && &1.rollup.depth) || 0))
    |> Enum.max(fn -> 0 end)
    |> Kernel.+(1)
  end

  ## Decorating -----------------------------------------------------------------

  @doc "Sets the `rollup` virtual field on every card of a loaded board."
  def decorate(%Board{} = board, %__MODULE__{} = rollup) do
    columns =
      if Ecto.assoc_loaded?(board.columns) do
        Enum.map(board.columns, fn col ->
          if Ecto.assoc_loaded?(col.cards),
            do: %{col | cards: Enum.map(col.cards, &put_stats(&1, rollup))},
            else: col
        end)
      else
        board.columns
      end

    cards =
      if Ecto.assoc_loaded?(board.cards),
        do: Enum.map(board.cards, &put_stats(&1, rollup)),
        else: board.cards

    %{board | columns: columns, cards: cards}
  end

  def decorate(board, _), do: board

  @doc "Sets the `rollup` virtual field on a card."
  def put_stats(%Card{} = card, %__MODULE__{} = rollup), do: %{card | rollup: stats(rollup, card)}
  def put_stats(card, _), do: card
end
