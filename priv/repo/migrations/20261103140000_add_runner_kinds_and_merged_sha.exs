defmodule Slipdock.Repo.Migrations.AddRunnerKindsAndMergedSha do
  use Ecto.Migration

  # Ship by PR 3 (#1656): the job kinds a runner says it takes (nil until it
  # says), and the commit a merge job's pull request was merged as.
  def change do
    alter table(:runners) do
      add :kinds, {:array, :string}
    end

    alter table(:runner_jobs) do
      add :merged_sha, :string
    end
  end
end
