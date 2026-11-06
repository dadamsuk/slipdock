defmodule Slipdock.Repo.Migrations.AddJobLogRetention do
  use Ecto.Migration

  # Job logs evaporate unless kept (#1872). Each top board says how long a
  # finished job's live log stays, and how long a failure's does. A job
  # records when its work turned out to be a failure after it ended (its
  # card rejected, flagged stuck or put back), the page Keep this log wrote,
  # and when the sweep deleted its log.
  def change do
    alter table(:boards) do
      add :job_log_hours, :integer, null: false, default: 24
      add :failure_log_hours, :integer, null: false, default: 168
    end

    alter table(:runner_jobs) do
      add :transcript_failed_at, :utc_datetime
      add :transcript_page_id, references(:pages, on_delete: :nilify_all)
      add :transcript_deleted_at, :utc_datetime
    end

    # What the sweep looks at: ended jobs with a log nobody kept.
    create index(:runner_jobs, [:finished_at],
             where: "transcript_bytes > 0 AND transcript_page_id IS NULL",
             name: :runner_jobs_transcript_to_expire_index
           )
  end
end
