defmodule Slipdock.Repo.Migrations.AddRecoveryToRunnerJobs do
  use Ecto.Migration

  # What the server did with a card its job left in progress, when the job's
  # rule puts such cards back (requeue_stuck): "requeued" or "gave_up".
  def change do
    alter table(:runner_jobs) do
      add :recovery, :string
    end
  end
end
