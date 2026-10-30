defmodule Slipdock.Repo.Migrations.AddQuickNoteLocationToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :quick_note_vault_id, references(:vaults, on_delete: :nilify_all)
      add :quick_note_folder, :string, size: 500
    end

    create index(:users, [:quick_note_vault_id])
  end
end
