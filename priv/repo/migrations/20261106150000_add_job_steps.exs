defmodule Slipdock.Repo.Migrations.AddJobSteps do
  use Ecto.Migration

  # Every step a job's agent reported (#1875), not just the latest: the
  # card chat reads them as the job's milestones, with their times.
  def change do
    alter table(:runner_jobs) do
      add :steps, {:array, :map}, null: false, default: []
    end
  end
end
