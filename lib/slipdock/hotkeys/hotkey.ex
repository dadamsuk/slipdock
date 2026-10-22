defmodule Slipdock.Hotkeys.Hotkey do
  @moduledoc """
  One person's Ctrl+Shift+digit for one board or one vault (#1204), never
  both. See `Slipdock.Hotkeys`.
  """
  use Ecto.Schema

  schema "board_hotkeys" do
    belongs_to :user, Slipdock.Accounts.User
    belongs_to :board, Slipdock.Boards.Board
    belongs_to :vault, Slipdock.Vaults.Vault
    field :digit, :integer
    timestamps(type: :utc_datetime)
  end
end
