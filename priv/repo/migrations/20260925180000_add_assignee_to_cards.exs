defmodule Slipdock.Repo.Migrations.AddAssigneeToCards do
  use Ecto.Migration

  def change do
    alter table(:cards) do
      add :assignee_id, references(:users, on_delete: :nilify_all)
    end

    create index(:cards, [:assignee_id])
  end
end
