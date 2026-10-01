defmodule Slipdock.Boards.BoardOrder do
  @moduledoc """
  Where one person has put a board on their own index.

  Like a favourite, the row belongs to the person rather than to the board:
  rearranging your boards never moves anyone else's, even when you are both
  looking at the same board. A board with no row has not been placed, and
  sits after the placed ones in the order it was created — which is where
  everything sat before boards could be rearranged at all.
  """
  use Ecto.Schema

  schema "board_orders" do
    belongs_to :user, Slipdock.Accounts.User
    belongs_to :board, Slipdock.Boards.Board
    field :position, :integer
    timestamps(type: :utc_datetime)
  end
end
