defmodule Slipdock.Repo.Migrations.AddExcludeRunnerToJobs do
  use Ecto.Migration

  # Verified work 4 (#1625): a verify job never goes to the runner that built
  # the card it checks. No foreign key: a runner removed later excludes nobody.
  def change do
    alter table(:runner_jobs) do
      add :exclude_runner_id, :integer
    end
  end
end
