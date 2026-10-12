defmodule Slipdock.Repo.Migrations.CreateWikiFiles do
  use Ecto.Migration

  # Files in a board's wiki that are not pages — the images, PDFs and
  # drawings a synced vault keeps beside its notes (W-103 R2.9). Filed in a
  # folder like a page (or at the wiki's root), not hanging off a page or a
  # card the way an attachment does. Archived rather than deleted when a
  # sync deletes one, so a delete is recoverable.
  def change do
    create table(:wiki_files) do
      add :board_id, references(:boards, on_delete: :delete_all), null: false
      add :folder_id, references(:page_folders, on_delete: :nilify_all)
      add :name, :string, null: false
      add :content_type, :string, null: false
      add :size, :bigint, null: false
      add :sha256, :string, null: false
      add :key, :string, null: false
      add :archived_at, :utc_datetime
      add :created_by_id, references(:users, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    create index(:wiki_files, [:board_id])
    create index(:wiki_files, [:folder_id])
    create unique_index(:wiki_files, [:key])
  end
end
