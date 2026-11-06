defmodule Slipdock.Repo.Migrations.AddJobTranscripts do
  use Ecto.Migration

  # A job's live log (#1870): the runner sends its agent's transcript as it
  # goes, in chunks of whole lines. The job keeps the running totals, so an
  # append needs no count over the chunks and a resend can be trimmed.
  def change do
    alter table(:runner_jobs) do
      add :transcript_lines, :integer, null: false, default: 0
      add :transcript_bytes, :integer, null: false, default: 0
      add :transcript_capped, :boolean, null: false, default: false
      add :transcript_at, :utc_datetime
    end

    create table(:runner_job_transcript_chunks) do
      add :job_id, references(:runner_jobs, on_delete: :delete_all), null: false
      # The runner's line number of the chunk's first line (0-based), and
      # how many of the runner's lines it holds. A note the server adds (the
      # cap) holds none.
      add :first_line, :integer, null: false
      add :lines, :integer, null: false
      add :bytes, :integer, null: false
      add :body, :text, null: false

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:runner_job_transcript_chunks, [:job_id, :id])
  end
end
