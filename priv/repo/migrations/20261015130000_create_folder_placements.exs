defmodule Slipdock.Repo.Migrations.CreateFolderPlacements do
  use Ecto.Migration

  # A folder has one home (`page_folders.parent_id`) and may be *also filed
  # in* other folders, like a symbolic link: one folder, one set of contents,
  # several places (see `Slipdock.Wiki.FolderPlacements`, #808). Deleting
  # either folder takes the placement with it; nothing else does.
  def change do
    create table(:folder_placements) do
      add :folder_id, references(:page_folders, on_delete: :delete_all), null: false
      add :in_folder_id, references(:page_folders, on_delete: :delete_all), null: false
      add :position, :integer, default: 0, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:folder_placements, [:folder_id, :in_folder_id])
    create index(:folder_placements, [:in_folder_id])
  end
end
