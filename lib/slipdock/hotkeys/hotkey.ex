defmodule Slipdock.Hotkeys.Hotkey do
  @moduledoc """
  One person's Ctrl+Shift+digit for one board. See `Slipdock.Hotkeys`.
  """
  use Ecto.Schema

  schema "board_hotkeys" do
    belongs_to :user, Slipdock.Accounts.User
    belongs_to :board, Slipdock.Boards.Board
    field :digit, :integer
    timestamps(type: :utc_datetime)
  end
end
