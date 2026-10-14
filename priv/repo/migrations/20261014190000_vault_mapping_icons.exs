defmodule Slipdock.Repo.Migrations.VaultMappingIcons do
  use Ecto.Migration

  # A board or folder mounted in a vault wears an icon and a colour in the
  # vault's tree (#797), as a board's own folders do (#792). A whole board
  # mounted there has no folder to hold them, so they are the mapping's.
  def change do
    alter table(:vault_mappings) do
      add :icon, :string
      add :color, :string
    end
  end
end
