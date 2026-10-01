defmodule Slipdock.Repo.Migrations.WikiFolders do
  use Ecto.Migration

  @moduledoc """
  Folders on a board's wiki: a tree of names, to any depth, that pages sit in.

  A page tree already existed — `pages.parent_id` — but it says something
  else. A child page is *part of* its parent: a section of the spec, the
  rollback half of the runbook. A folder is filing: "Design", "Contracts",
  "Meetings", holding documents that have nothing to do with one another
  except where they are kept. Conflating the two forces anyone who wants a
  place to put things to invent a parent page that is not about anything.

  So the two axes are kept apart, and both are optional. A page carries a
  `folder_id` (where it is filed) and a `parent_id` (what it is part of); the
  sidebar draws folders first and then the page trees filed in each.

  Deleting a folder never deletes writing: its pages fall back to the board's
  root and its subfolders move up to its parent.
  """

  def change do
    create table(:page_folders) do
      add :board_id, references(:boards, on_delete: :delete_all), null: false
      add :parent_id, references(:page_folders, on_delete: :nilify_all)
      add :name, :string, null: false
      add :slug, :string, null: false
      add :position, :integer, null: false, default: 0

      timestamps(type: :utc_datetime)
    end

    create index(:page_folders, [:board_id])
    create index(:page_folders, [:parent_id])
    create unique_index(:page_folders, [:board_id, :slug])

    alter table(:pages) do
      add :folder_id, references(:page_folders, on_delete: :nilify_all)
    end

    create index(:pages, [:folder_id])
  end
end
