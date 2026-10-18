defmodule Slipdock.Repo.Migrations.AddVaultPosition do
  use Ecto.Migration

  # Where the vault sits among its owner's boards on the home page, in the
  # same numbering as their board_orders rows. Nil until it has been placed.
  def change do
    alter table(:vaults) do
      add :position, :integer
    end
  end
end
