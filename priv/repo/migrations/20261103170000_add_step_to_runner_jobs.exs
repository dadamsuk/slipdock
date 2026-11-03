defmodule Slipdock.Repo.Migrations.AddStepToRunnerJobs do
  use Ecto.Migration

  # #1668: the latest progress message a job's agent gave (`job-progress
  # --step`), and when. Not a card comment: it shows against the job.
  def change do
    alter table(:runner_jobs) do
      add :step, :text
      add :step_at, :utc_datetime
    end
  end
end
