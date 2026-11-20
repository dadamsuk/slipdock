defmodule Slipdock.Repo.Migrations.AddRunnerJobsQuarantinedRead do
  use Ecto.Migration

  # What the quarantined reader made of an `anyone`-tier job's card text
  # (#3531): its checked fields and the hash of the text it read, so a
  # claim of the same card text reads it once.
  def change do
    alter table(:runner_jobs) do
      add :quarantined_read, :map
    end
  end
end
