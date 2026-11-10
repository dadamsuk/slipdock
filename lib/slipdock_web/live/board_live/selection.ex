defmodule SlipdockWeb.BoardLive.Selection do
  @moduledoc """
  Select mode's picking (#592, #2690): one card at a time, a run of them
  with shift-click, or a whole list from its header.

  Everything here works on the board as it is drawn: `columns` is the
  board's `@columns` (`SlipdockWeb.BoardLive.State`), each with its `groups`
  of `{kind, item}`. The order a run follows is that drawing order: down a
  list, then across to the next. Only cards count: a placed wiki page and a
  stand-in (which marks where a card went, and is not the work) are never
  picked, and neither is a card the filters hide, since it isn't shown.
  """

  alias Slipdock.Boards.Card

  @doc """
  The cards the board shows, in the order it shows them.
  """
  def shown_ids(columns), do: Enum.flat_map(columns, &list_ids/1)

  @doc """
  A click on card `id`: `{selected, anchor}` after it.

  A plain click toggles the one card and makes it the run's starting point.
  A shift-click adds every card from the starting point to `id`, both ends
  included, and keeps the starting point, so a second shift-click reshapes
  from the same place. With no starting point, or one no longer shown (it
  was filtered out, moved off the board or archived), a shift-click is a
  plain click.
  """
  def pick(selected, anchor, columns, id, shift?)

  def pick(selected, anchor, columns, id, true) when not is_nil(anchor) do
    ids = shown_ids(columns)

    with from when is_integer(from) <- Enum.find_index(ids, &(&1 == anchor)),
         to when is_integer(to) <- Enum.find_index(ids, &(&1 == id)) do
      run = ids |> Enum.slice(min(from, to)..max(from, to)//1) |> MapSet.new()
      {MapSet.union(selected, run), anchor}
    else
      _ -> pick(selected, nil, columns, id, false)
    end
  end

  def pick(selected, _anchor, _columns, id, _shift?) do
    if MapSet.member?(selected, id),
      do: {MapSet.delete(selected, id), id},
      else: {MapSet.put(selected, id), id}
  end

  @doc """
  The list header's select-all: every card list `column_id` shows is added,
  or, when they are all selected already, taken out. A list showing no cards
  leaves the selection as it was.
  """
  def toggle_list(selected, columns, column_id) do
    ids = columns |> Enum.find(&(&1.column.id == column_id)) |> list_ids() |> MapSet.new()

    cond do
      MapSet.size(ids) == 0 -> selected
      MapSet.subset?(ids, selected) -> MapSet.difference(selected, ids)
      true -> MapSet.union(selected, ids)
    end
  end

  @doc """
  Whether every card list `column` shows is selected (and it shows some).
  """
  def all_selected?(selected, column) do
    case list_ids(column) do
      [] -> false
      ids -> Enum.all?(ids, &MapSet.member?(selected, &1))
    end
  end

  defp list_ids(nil), do: []

  defp list_ids(%{groups: groups}) do
    for group <- groups,
        {:card, %Card{} = card} <- group.items,
        not Card.stand_in?(card),
        do: card.id
  end
end
