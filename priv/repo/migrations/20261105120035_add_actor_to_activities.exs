defmodule Slipdock.Repo.Migrations.AddActorToActivities do
  use Ecto.Migration

  # Who made each change on a board's activity log (#1735). `actor_name` is a
  # snapshot taken at the time, so a deleted user's entries still name them
  # once `user_id` has been nilified. Rows from before this have no actor at
  # all and are shown as "Someone".
  def change do
    alter table(:activities) do
      add :user_id, references(:users, on_delete: :nilify_all)
      add :actor_kind, :string
      add :actor_name, :string
    end

    create index(:activities, [:user_id])
  end
end
