defmodule Slipdock.Repo.Migrations.AddRunnerDrift do
  use Ecto.Migration

  # What a runner says it has installed (#1795): the SHA-256 of each slipdock
  # skill's SKILL.md and of its `slipdock` CLI, and the alert raised while
  # either differs from what the server serves.
  def change do
    alter table(:runners) do
      add :skills, :map
      add :cli_sha, :string
      add :drift_alert_id, references(:alerts, on_delete: :nilify_all)
    end
  end
end
