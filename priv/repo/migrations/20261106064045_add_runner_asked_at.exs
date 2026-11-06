defmodule Slipdock.Repo.Migrations.AddRunnerAskedAt do
  use Ecto.Migration

  # When a runner last asked for a job (#1849). One that asks again after
  # claiming the job it holds takes more than one at a time (several
  # processes on one token, a session), so the health monitor doesn't count
  # it busy.
  def change do
    alter table(:runners) do
      add :asked_at, :utc_datetime
    end
  end
end
