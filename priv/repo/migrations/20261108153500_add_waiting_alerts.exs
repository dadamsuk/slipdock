defmodule Slipdock.Repo.Migrations.AddWaitingAlerts do
  use Ecto.Migration

  # #2095: an alert can be one person's (a wait on them), and each person
  # can turn those alerts, and the wait email, off.
  def change do
    alter table(:alerts) do
      add :user_id, references(:users, on_delete: :delete_all)
    end

    create index(:alerts, [:user_id])

    alter table(:users) do
      add :waiting_alerts, :boolean, default: true, null: false
      add :waiting_emails, :boolean, default: true, null: false
    end
  end
end
