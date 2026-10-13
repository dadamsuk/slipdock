defmodule Slipdock.Repo.Migrations.AddSortToFolders do
  use Ecto.Migration

  # How a folder's pages are ordered in the wiki's tree (W-103 R11.9):
  # "manual" (as dragged), "name", "modified" or "created". The top of a
  # board's wiki has no folder row, so the board keeps its own.
  def change do
    alter table(:page_folders) do
      add :sort, :string, null: false, default: "manual"
    end

    alter table(:boards) do
      add :wiki_sort, :string, null: false, default: "manual"
    end
  end
end
