defmodule Slipdock.Repo.Migrations.CreateVaults do
  use Ecto.Migration

  # A vault is one logical Obsidian-style vault made of board wikis: each
  # mapping says which vault path lands in which board's wiki, or in one
  # folder of it (see `Slipdock.Vaults`, W-103).
  def change do
    create table(:vaults) do
      add :name, :string, null: false
      add :user_id, references(:users, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:vaults, [:user_id, "lower(name)"], name: :vaults_user_id_name_index)

    create table(:vault_mappings) do
      add :vault_id, references(:vaults, on_delete: :delete_all), null: false
      # Vault-relative, no leading or trailing slash; "" is the vault's root.
      add :path, :string, null: false, default: ""
      add :board_id, references(:boards, on_delete: :delete_all), null: false
      add :folder_id, references(:page_folders, on_delete: :delete_all)

      timestamps(type: :utc_datetime)
    end

    create unique_index(:vault_mappings, [:vault_id, :path])
    create index(:vault_mappings, [:board_id])

    # One board wiki, or one folder of it, belongs to one vault.
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
