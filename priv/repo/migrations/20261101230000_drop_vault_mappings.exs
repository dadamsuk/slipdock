defmodule Slipdock.Repo.Migrations.DropVaultMappings do
  use Ecto.Migration

  # One wiki per person (W-2201, #1603): nothing is mounted, so the mappings
  # table has been empty since the move to the root vault, and a person has
  # exactly one vault row. `down` puts the table back as it was, empty.
  def up do
    drop table(:vault_mappings)
    create unique_index(:vaults, [:user_id], name: :vaults_one_per_user_index)
  end

  def down do
    drop index(:vaults, [:user_id], name: :vaults_one_per_user_index)

    create table(:vault_mappings) do
      add :vault_id, references(:vaults, on_delete: :delete_all), null: false
      add :path, :string, null: false, default: ""
      add :board_id, references(:boards, on_delete: :delete_all), null: false
      add :folder_id, references(:page_folders, on_delete: :delete_all)
      add :inside, :boolean, null: false, default: false
      add :icon, :string
      add :color, :string

      timestamps(type: :utc_datetime)
    end

    create unique_index(:vault_mappings, [:vault_id, :path])
    create index(:vault_mappings, [:board_id])

    create unique_index(:vault_mappings, [:board_id],
             where: "folder_id IS NULL",
             name: :vault_mappings_board_root_index
           )

    create unique_index(:vault_mappings, [:folder_id],
             where: "folder_id IS NOT NULL",
             name: :vault_mappings_folder_index
           )
  end
end
