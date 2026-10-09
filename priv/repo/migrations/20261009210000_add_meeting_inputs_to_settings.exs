defmodule Slipdock.Repo.Migrations.AddMeetingInputsToSettings do
  use Ecto.Migration

  def change do
    # What a capture may be sent: each on or off for the whole server.
    alter table(:settings) do
      add :meetings_accept_transcripts, :boolean, default: true, null: false
      add :meetings_accept_audio, :boolean, default: true, null: false
      add :meetings_accept_findings, :boolean, default: true, null: false
    end
  end
end
