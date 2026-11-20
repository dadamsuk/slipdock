defmodule Slipdock.Repo.Migrations.AddRunnerJobsReadMark do
  use Ecto.Migration

  # What a job's reads are held to (#3520): its tier at claim, the card's
  # text as it was then, the hash of the key its machine's hook asks with,
  # and when (and why) a read of less-trusted text marked it.
  def change do
    alter table(:runner_jobs) do
      add :prompt_tier, :string
      add :claim_text, :map
      add :hook_key_hash, :binary
      add :marked_at, :utc_datetime
      add :mark_reason, :string
    end
  end
end
