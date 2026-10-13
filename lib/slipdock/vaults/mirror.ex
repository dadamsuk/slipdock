defmodule Slipdock.Vaults.Mirror do
  @moduledoc """
  A folder a vault is synced to, as the server sees it: the API token that
  listed the vault or followed its change feed, its label (which names the
  machine, `slipdock CLI on laptop`), and when it last did. One row per
  vault and token, touched by `Slipdock.Vaults.touch_mirror/2`.
  """
  use Ecto.Schema

  schema "vault_mirrors" do
    field :label, :string
    field :last_synced_at, :utc_datetime

    belongs_to :vault, Slipdock.Vaults.Vault
    belongs_to :token, Slipdock.Accounts.UserToken

    timestamps(type: :utc_datetime)
  end
end
