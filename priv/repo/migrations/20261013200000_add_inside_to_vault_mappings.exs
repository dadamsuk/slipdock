defmodule Slipdock.Repo.Migrations.AddInsideToVaultMappings do
  use Ecto.Migration

  # A board mapped whole into a vault can be kept inside it (#757): for the
  # vault's owner it leaves the home page's board list and is named on the
  # vault's tile instead.
  def change do
    alter table(:vault_mappings) do
      add :inside, :boolean, null: false, default: false
    end
  end
end
