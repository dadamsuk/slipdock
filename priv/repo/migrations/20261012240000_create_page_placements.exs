defmodule Slipdock.Repo.Migrations.CreatePagePlacements do
  use Ecto.Migration

  # A page has one home folder (`pages.folder_id`) and may be *also filed in*
  # others, like a symbolic link: one body, one history, several places
  # (see `Slipdock.Wiki.Placements`, W-103 R12). Deleting the page or the
  # folder takes the placement with it; nothing else does.
  def change do
    create table(:page_placements) do
      add :page_id, references(:pages, on_delete: :delete_all), null: false
      add :folder_id, references(:page_folders, on_delete: :delete_all), null: false
      add :position, :integer, default: 0, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:page_placements, [:page_id, :folder_id])
    create index(:page_placements, [:folder_id])
  end
end
