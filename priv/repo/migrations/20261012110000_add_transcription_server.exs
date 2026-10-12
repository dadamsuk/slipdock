defmodule Slipdock.Repo.Migrations.AddTranscriptionServer do
  use Ecto.Migration

  # A transcription server the admin names (a Manuel2 server, or anything that
  # speaks its API), and what it made of each recording attached to a card.
  def change do
    alter table(:settings) do
      add :transcription_server_url, :string
      add :transcription_server_token, :string
    end

    alter table(:attachments) do
      add :transcript, :text
      # nil (never asked), "running", "done" or "failed".
      add :transcript_status, :string
      add :transcript_error, :string
      add :transcript_started_at, :utc_datetime
    end
  end
end
