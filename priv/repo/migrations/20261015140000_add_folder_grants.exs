defmodule Slipdock.Repo.Migrations.AddFolderGrants do
  use Ecto.Migration

  # A grant on a wiki folder (#815): everything whose home is in that
  # folder's subtree is shared with it — pages, files, drawings and the
  # folders beneath. Deleting the folder takes the grant with it.
  def change do
    alter table(:access_grants) do
      add :folder_id, references(:page_folders, on_delete: :delete_all)
    end

    create index(:access_grants, [:folder_id])
  end
end
