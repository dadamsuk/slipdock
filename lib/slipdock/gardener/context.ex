defmodule Slipdock.Gardener.Context do
  @moduledoc """
  What a check is given to read (W-1807): the board the run is on, the ids
  of it and every board beneath it (its cards' subcards, all the way down),
  the rolled-up tree, every list on those boards by id, and the moment the
  run is for.
  """

  alias Slipdock.Boards.Board
  alias Slipdock.Rollup

  defstruct [:board, :board_ids, :rollup, :columns, :now, :today]

  @type t :: %__MODULE__{
          board: Board.t(),
          board_ids: [integer],
          rollup: Rollup.t(),
          columns: %{integer => Slipdock.Boards.Column.t()},
          now: DateTime.t(),
          today: Date.t()
        }

  @doc "The context for a run on `board` at `now`."
  def new(%Board{} = board, now \\ DateTime.utc_now()) do
    today = DateTime.to_date(now)
    rollup = Rollup.build(board, today)
    board_ids = subtree(rollup, board.id)

    columns =
      for id <- board_ids,
          b = Rollup.board(rollup, id),
          is_list(b.columns),
          col <- b.columns,
          into: %{},
          do: {col.id, col}

    %__MODULE__{
      board: board,
      board_ids: board_ids,
      rollup: rollup,
      columns: columns,
      now: DateTime.truncate(now, :second),
      today: today
    }
  end

  # The board and every board hanging off one of its cards, recursively.
  defp subtree(rollup, board_id) do
    subs =
      for card <- Rollup.board_cards(rollup, board_id),
          sub = Map.get(rollup.sub_board, card.id),
          do: sub

    [board_id | Enum.flat_map(subs, &subtree(rollup, &1))]
  end

  @doc "The category of the list a card sits in (`todo`, `doing`, `done`, `dropped`), or nil."
  def category(%__MODULE__{columns: columns}, %{column_id: id}) do
    case Map.get(columns, id) do
      %{category: category} -> category
      nil -> nil
    end
  end

  @doc "The lists of `board_id` in the tree, in order."
  def board_columns(%__MODULE__{rollup: rollup}, board_id) do
    case Rollup.board(rollup, board_id) do
      %{columns: columns} when is_list(columns) -> columns
      _ -> []
    end
  end

  @doc "The first list of `board_id` with that category, or nil."
  def first_column(%__MODULE__{} = ctx, board_id, category) do
    ctx |> board_columns(board_id) |> Enum.find(&(&1.category == category))
  end
end
