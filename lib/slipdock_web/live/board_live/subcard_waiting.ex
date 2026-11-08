defmodule SlipdockWeb.BoardLive.SubcardWaiting do
  @moduledoc """
  What in an open epic's tree waits on the reader, laid over its subcard
  list (#2126): the board's `Slipdock.Work.Tree` entry for the card
  (`Tree.of/2`, the same one its tile's glance line reads), with each item
  put on the subcard row it sits under, so the panel can mark that row and
  the glance line's #ids can jump to it.

  An item deeper down (a subcard's subcard) marks the row of the subcard
  it sits beneath, naming its own #id beside the reason.
  """

  alias Slipdock.Boards
  alias Slipdock.Boards.{Board, Card, Wait}
  alias Slipdock.Work.Tree

  @type item :: %{id: integer(), row: integer() | nil, reason: String.t()}
  @type t :: %{
          mine: [item()],
          others: [item()],
          rows: %{optional(integer()) => %{mine: [item()], others: [item()]}}
        }

  @empty %{mine: [], others: [], rows: %{}}

  @doc "Nothing waiting: no line, no markers."
  def empty, do: @empty

  @doc """
  The entry (`%{mine: [...], others: [...]}`, as `Tree.of/2` gives it) for
  `card`, with each item's reason in a few words (`Tree.short/1` for mine,
  `on <name>` for someone else's) and the id of the row on `card`'s
  sub-board it falls under (nil when it is not under one).
  """
  @spec build(map() | nil, Card.t() | nil) :: t()
  def build(%{mine: mine, others: others}, %Card{sub_board: %Board{id: sub_id}})
      when mine != [] or others != [] do
    mine = Enum.map(mine, &%{id: &1.card.id, row: row(&1.card, sub_id), reason: Tree.short(&1)})

    others =
      Enum.map(
        others,
        &%{id: &1.card.id, row: row(&1.card, sub_id), reason: "on " <> Wait.on_name(&1)}
      )

    rows =
      %{}
      |> file(mine, :mine)
      |> file(others, :others)

    %{mine: mine, others: others, rows: rows}
  end

  def build(_entry, _card), do: @empty

  @doc "A row's entry: `%{mine: [], others: []}` when nothing under it waits."
  def row_entry(%{rows: rows}, row_id), do: Map.get(rows, row_id, %{mine: [], others: []})

  @doc """
  A row marker's words: each item's reason, with its #id in front when it
  is not the row's own card (`to verify`, `#2120 a question`).
  """
  def label(items, row_id) do
    items
    |> Enum.map(fn
      %{id: ^row_id, reason: reason} -> reason
      %{id: id, reason: reason} -> "##{id} #{reason}"
    end)
    |> Enum.uniq()
    |> Enum.join(", ")
  end

  defp file(acc, items, key) do
    items
    |> Enum.reject(&is_nil(&1.row))
    |> Enum.reduce(acc, fn item, acc ->
      acc
      |> Map.put_new(item.row, %{mine: [], others: []})
      |> update_in([item.row, key], &(&1 ++ [item]))
    end)
  end

  # The card on the sub-board an item's card sits under: itself when it is
  # on it, else the sub-board card above it.
  defp row(%Card{board_id: sub_id, id: id}, sub_id), do: id

  defp row(%Card{board: %Board{} = board}, sub_id) do
    case Enum.find(Boards.ancestry(board), &(&1.board.id == sub_id)) do
      %{card: %Card{id: id}} -> id
      nil -> nil
    end
  end

  defp row(_card, _sub_id), do: nil
end
