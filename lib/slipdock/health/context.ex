defmodule Slipdock.Health.Context do
  @moduledoc """
  What a detector is given to read: the root board, the ids of it and every
  board beneath it, every list on those boards by id, and the moment the run
  is for.
  """

  alias Slipdock.Boards.Board
  alias Slipdock.Gardener

  defstruct [:board, :board_ids, :columns, :now]

  @type t :: %__MODULE__{
          board: Board.t(),
          board_ids: [integer],
          columns: %{integer => Slipdock.Boards.Column.t()},
          now: DateTime.t()
        }

  @doc "The context for a run on the tree rooted at `board`, at `now`."
  def new(%Board{} = board, now \\ DateTime.utc_now()) do
    tree = Gardener.Context.new(board, now)

    %__MODULE__{
      board: board,
      board_ids: tree.board_ids,
      columns: tree.columns,
      now: DateTime.truncate(now, :second)
    }
  end

  @doc "The category of the list with that id (`todo`, `doing`, `done`, `dropped`), or nil."
  def category(%__MODULE__{columns: columns}, column_id) do
    case Map.get(columns, column_id) do
      %{category: category} -> category
      _ -> nil
    end
  end

  @doc "Minutes from `at` to the run's moment (0 for nil or the future)."
  def minutes_since(_ctx, nil), do: 0

  def minutes_since(%__MODULE__{now: now}, %DateTime{} = at),
    do: max(DateTime.diff(now, at, :minute), 0)

  def minutes_since(ctx, %NaiveDateTime{} = at),
    do: minutes_since(ctx, DateTime.from_naive!(at, "Etc/UTC"))
end
