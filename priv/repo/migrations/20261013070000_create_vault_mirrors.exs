defmodule Slipdock.Repo.Migrations.CreateVaultMirrors do
  use Ecto.Migration

  # The folders a vault is synced to, as far as the server can tell: one row
  # per API token that has listed the vault or followed its feed, with when it
  # last did. The vaults screen shows them, and deleting a vault names them.
  def change do
    create table(:vault_mirrors) do
      add :vault_id, references(:vaults, on_delete: :delete_all), null: false
      add :token_id, references(:users_tokens, on_delete: :delete_all), null: false
      add :label, :string
      add :last_synced_at, :utc_datetime, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:vault_mirrors, [:vault_id, :token_id])
  end
end
