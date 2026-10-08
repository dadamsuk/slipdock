defmodule Slipdock.Repo.Migrations.AddWaitWhileDoingToRunnerJobs do
  use Ecto.Migration

  # A job queued by a rule that waits while anything is in progress on the
  # card's board: claim passes it over until that list is clear.
  def change do
    alter table(:runner_jobs) do
      add :wait_while_doing, :boolean, null: false, default: false
    end
  end
end
