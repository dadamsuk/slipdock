defmodule Slipdock.Repo.Migrations.AddUserIdToComments do
  use Ecto.Migration

  # Who wrote a comment (#668). nil for every comment written before, and for
  # those the system writes itself (automations, recovery notes); a deleted
  # account leaves its comments standing, unattributed.
  def change do
    alter table(:comments) do
      add :user_id, references(:users, on_delete: :nilify_all)
    end

    create index(:comments, [:user_id])
  end
end
