defmodule Slipdock.HeaderLinks.HeaderLink do
  @moduledoc """
  One link a person pinned to the header (#1205): a board or one of their
  vaults, never both, drawn as an icon from `Slipdock.Wiki.Icons`. See
  `Slipdock.HeaderLinks`.
  """
  use Ecto.Schema

  schema "header_links" do
    belongs_to :user, Slipdock.Accounts.User
    belongs_to :board, Slipdock.Boards.Board
    belongs_to :vault, Slipdock.Vaults.Vault
    field :icon, :string
    field :position, :integer, default: 0
    timestamps(type: :utc_datetime)
  end
end
