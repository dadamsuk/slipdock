defmodule Slipdock.Boards.Columns do
  @moduledoc """
  Lists (columns) on a board, and the order of what sits in one: cards and
  the wiki pages placed on the board share one position sequence.
  """

  import Ecto.Query, warn: false

  alias Slipdock.Boards
  alias Slipdock.Boards.Board
  alias Slipdock.Boards.Card
  alias Slipdock.Boards.Column
  alias Slipdock.Repo

  ## Columns

  def get_column!(id), do: Repo.get!(Column, id)

  @doc "The list `id` if it is on `board_id`, or nil: for ids a client sent."
  def get_board_column(board_id, id) do
    case Boards.Shared.to_id(id) do
      nil -> nil
      id -> Repo.one(from(c in Column, where: c.id == ^id and c.board_id == ^board_id))
    end
  end

  @doc """
  `board`'s Scheduled list (category `scheduled`, #2100), where recurring
  agent work lands, or nil.
  """
  def scheduled_column(%Board{id: board_id}) do
    Repo.one(
      from(c in Column,
        where: c.board_id == ^board_id and c.category == "scheduled",
        order_by: [asc: c.position, asc: c.id],
        limit: 1
      )
    )
  end

  def create_column(%Board{} = board, attrs) do
    position = Boards.Shared.next_position(from(c in Column, where: c.board_id == ^board.id))

    %Column{board_id: board.id, position: position}
    |> Column.changeset(attrs |> Map.put("board_id", board.id) |> default_category())
    |> Repo.insert()
    |> Boards.Shared.tap_ok(fn col ->
      Boards.ActivityLog.log(Repo, board.id, nil, "column", "added list “#{col.name}”")
      Boards.PubSub.broadcast(board.id)
      if sibling_list?(col), do: scheduled_feeds(col)
    end)
  end

  def update_column(%Column{} = column, attrs) do
    column
    |> Column.changeset(attrs)
    |> Repo.update()
    |> Boards.Shared.tap_ok(&Boards.PubSub.broadcast(&1.board_id))
    |> Boards.Shared.tap_ok(fn col ->
      if sibling_list?(col) and col.category != column.category, do: scheduled_feeds(col)
    end)
  end

  # A new list given no category takes the one its name says, if any
  # (`Column.default_category/1`): a list called Housekeeping (#2777).
  defp default_category(attrs) do
    given = Map.get(attrs, "category", Map.get(attrs, :category))
    name = Map.get(attrs, "name", Map.get(attrs, :name))

    case {given, Column.default_category(name)} do
      {blank, category} when blank in [nil, ""] and is_binary(category) ->
        attrs |> Map.delete(:category) |> Map.put("category", category)

      _ ->
        attrs
    end
  end

  # A list whose feeds are siblings of the ready list's: Scheduled (#2100)
  # and Housekeeping (#2777).
  defp sibling_list?(col), do: Column.scheduled?(col) or Column.housekeeping?(col)

  # A list that has just become the board's Scheduled or Housekeeping list
  # (#2100, #2777): the ready list's feeds get a sibling working it. A
  # sibling that can't be made (the board is at its rule limit) leaves the
  # list as it is.
  defp scheduled_feeds(%Column{board_id: board_id}) do
    case Slipdock.Automations.ScheduledFeed.ensure(board_id) do
      {:ok, _made} ->
        :ok

      {:error, message} ->
        require Logger
        Logger.warning("Scheduled feeds on board #{board_id}: #{message}")
        :ok
    end
  end

  def delete_column(%Column{} = column) do
    # The cards go with the list by a cascade, archived ones too; their files
    # and everything beneath them have to be gathered first.
    keys =
      Boards.Attachments.card_file_keys(
        Repo.all(from(c in Card, where: c.column_id == ^column.id, select: c.id))
      )

    Repo.delete(column)
    |> Boards.Shared.tap_ok(fn col ->
      Boards.Attachments.remove_files(keys)
      Boards.ActivityLog.log(Repo, col.board_id, nil, "column", "deleted list “#{col.name}”")
      Boards.PubSub.broadcast(col.board_id)
    end)
  end

  @doc """
  How many cards deleting `column` would take with it: `{total, archived}`.
  Archived cards count — the foreign key deletes them along with the rest.
  """
  def column_card_counts(%Column{id: id}) do
    Repo.one(
      from(c in Card,
        where: c.column_id == ^id,
        select: {count(c.id), filter(count(c.id), not is_nil(c.archived_at))}
      )
    )
  end

  def change_column(%Column{} = column, attrs \\ %{}), do: Column.changeset(column, attrs)

  @doc """
  Moves a column so that it sits directly before `before_id`, or at the end
  of the board when `before_id` is nil.
  """
  def move_column(board_id, column_id, before_id) do
    ids =
      Repo.all(
        from(c in Column, where: c.board_id == ^board_id, order_by: c.position, select: c.id)
      )

    if Enum.member?(ids, column_id) do
      reordered = insert_before(List.delete(ids, column_id), column_id, before_id)

      Repo.transaction(fn -> set_positions(reordered) end)

      Boards.PubSub.broadcast(board_id)
      :ok
    else
      {:error, :not_found}
    end
  end

  defp set_positions(ids) do
    ids
    |> Enum.with_index()
    |> Enum.each(fn {id, i} ->
      from(c in Column, where: c.id == ^id and c.position != ^i)
      |> Repo.update_all(set: [position: i])
    end)
  end

  @doc false
  def insert_before(ids, moving, nil), do: ids ++ [moving]

  def insert_before(ids, moving, before_id) do
    case Enum.find_index(ids, &(&1 == before_id)) do
      nil -> ids ++ [moving]
      i -> List.insert_at(ids, i, moving)
    end
  end

  ## Ordering a list ----------------------------------------------------------
  #
  # A list holds cards and, sometimes, wiki pages placed on the board (see
  # `Slipdock.Wiki.place/3`). They share one position sequence so the two
  # interleave: a document that had to sit after every card would not really
  # be on the board. Everything below therefore works on **refs** —
  # `{:card, id}` or `{:page, id}` — rather than bare card ids.

  @typedoc "A thing that can sit in a list: a card, or a wiki page placed on the board."
  @type item_ref :: {:card, integer} | {:page, integer}

  @doc """
  Moves one item into a list, before another item (or to the end), repacking
  both the list it left and the one it joined.

  `before` may be a ref, a bare card id, or the `"page-7"` form the board's
  drag-and-drop sends back.
  """
  @spec reorder(item_ref, integer | nil, integer, term) :: :ok
  def reorder(ref, from_column_id, to_column_id, before \\ nil) do
    same_column? = from_column_id == to_column_id
    before_ref = item_ref(before)

    Repo.transaction(fn ->
      from_items = if from_column_id, do: active_items(from_column_id), else: []
      to_items = if same_column?, do: from_items, else: active_items(to_column_id)

      from_items = List.delete(from_items, ref)
      to_items = insert_before(List.delete(to_items, ref), ref, before_ref)

      unless same_column?, do: repack(from_items, from_column_id)
      repack(to_items, to_column_id)
    end)

    :ok
  end

  @doc """
  Reads the `id` a board's drag-and-drop sends back. Cards send their number
  as they always have; a placed page sends `"page-7"`, so an older client can
  never accidentally move a page.
  """
  @spec item_ref(term) :: item_ref | nil
  def item_ref(nil), do: nil
  def item_ref(""), do: nil
  def item_ref({kind, id}) when kind in [:card, :page] and is_integer(id), do: {kind, id}
  def item_ref(id) when is_integer(id), do: {:card, id}

  def item_ref("page-" <> id) do
    case Integer.parse(id) do
      {id, ""} -> {:page, id}
      _ -> nil
    end
  end

  def item_ref(id) when is_binary(id) do
    case Integer.parse(id) do
      {id, ""} -> {:card, id}
      _ -> nil
    end
  end

  def item_ref(_), do: nil

  @doc """
  Closes a list's order up after something has left it, so positions stay a
  dense 0..n rather than developing gaps.
  """
  @spec repack_column(integer | nil) :: :ok
  def repack_column(nil), do: :ok

  def repack_column(column_id) do
    repack(active_items(column_id), column_id)
    :ok
  end

  @doc "What a list holds, in order: its cards and any wiki pages placed in it."
  @spec active_items(integer) :: [item_ref]
  def active_items(column_id) do
    cards =
      from(c in Card,
        where: c.column_id == ^column_id and is_nil(c.archived_at),
        select: {c.position, c.id, 0}
      )
      |> Repo.all()
      |> Enum.map(fn {position, id, _} -> {position, 0, {:card, id}} end)

    pages =
      from(p in Slipdock.Wiki.Page,
        where: p.column_id == ^column_id and is_nil(p.archived_at),
        select: {p.board_position, p.id}
      )
      |> Repo.all()
      |> Enum.map(fn {position, id} -> {position, 1, {:page, id}} end)

    # Ties break cards-first, then by id, so the order is stable whatever
    # order the two queries came back in.
    (cards ++ pages) |> Enum.sort() |> Enum.map(&elem(&1, 2))
  end

  @doc false
  def repack(refs, column_id) do
    refs
    |> Enum.with_index()
    |> Enum.each(fn
      {{:card, id}, i} ->
        from(c in Card, where: c.id == ^id)
        |> Repo.update_all(set: [position: i, column_id: column_id])

      {{:page, id}, i} ->
        from(p in Slipdock.Wiki.Page, where: p.id == ^id)
        |> Repo.update_all(set: [board_position: i, column_id: column_id])
    end)
  end
end
