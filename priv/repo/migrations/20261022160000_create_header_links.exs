defmodule Slipdock.Repo.Migrations.CreateHeaderLinks do
  use Ecto.Migration

  # Links a person pins to the header, left of quick add (#1205): each one a
  # board or a vault of theirs, never both, drawn as the icon they chose.
  def change do
    create table(:header_links) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :board_id, references(:boards, on_delete: :delete_all)
      add :vault_id, references(:vaults, on_delete: :delete_all)
      add :icon, :string, null: false
      add :position, :integer, null: false, default: 0
      timestamps(type: :utc_datetime)
    end

    create index(:header_links, [:user_id, :position])
    create unique_index(:header_links, [:user_id, :board_id])
    create unique_index(:header_links, [:user_id, :vault_id])
    create index(:header_links, [:board_id])
    create index(:header_links, [:vault_id])

    create constraint(:header_links, :header_links_one_target,
             check: "(board_id IS NULL) <> (vault_id IS NULL)"
           )
  end
end
