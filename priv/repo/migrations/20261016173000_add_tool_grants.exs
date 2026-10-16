defmodule Slipdock.Repo.Migrations.AddToolGrants do
  use Ecto.Migration

  # A Tool shared with a person or a group (#963): they can see it and
  # install it. Deleting the Tool takes the grant with it.
  def change do
    alter table(:access_grants) do
      add :tool_id, references(:tools, on_delete: :delete_all)
    end

    create index(:access_grants, [:tool_id])
  end
end
