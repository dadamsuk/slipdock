defmodule Slipdock.Repo.Migrations.AddUsersTokensJobId do
  use Ecto.Migration

  # A token minted for one runner job (#3522, context "job"): it lives as
  # long as its job runs, and goes with the job.
  def change do
    alter table(:users_tokens) do
      add :job_id, references(:runner_jobs, on_delete: :delete_all)
    end

    create index(:users_tokens, [:job_id])
  end
end
