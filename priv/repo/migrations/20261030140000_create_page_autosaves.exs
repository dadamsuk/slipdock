defmodule Slipdock.Repo.Migrations.CreatePageAutosaves do
  use Ecto.Migration

  # What a person has typed into the wiki's editor and not saved yet (#1532).
  # A row with no `page_id` is a new page that does not exist yet. The files
  # have their own table, not an owner on `attachments`: they are nobody's
  # attachments until the page is saved, and nothing that reads attachments
  # (quota, OCR, exports, sync) should ever see them.
  def change do
    create table(:page_autosaves) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :board_id, references(:boards, on_delete: :delete_all), null: false
      add :page_id, references(:pages, on_delete: :delete_all)
      add :attrs, :map, null: false, default: %{}
      add :base_hash, :string

      timestamps(type: :utc_datetime)
    end

    create unique_index(:page_autosaves, [:user_id, :page_id],
             where: "page_id IS NOT NULL",
             name: :page_autosaves_user_page_index
           )

    create index(:page_autosaves, [:user_id, :board_id])
    create index(:page_autosaves, [:updated_at])

    create table(:page_autosave_files) do
      add :autosave_id, references(:page_autosaves, on_delete: :delete_all), null: false
      add :filename, :string, null: false
      add :content_type, :string, null: false
      add :size, :bigint, null: false
      add :key, :string, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:page_autosave_files, [:autosave_id])
    create unique_index(:page_autosave_files, [:key])
  end
end
