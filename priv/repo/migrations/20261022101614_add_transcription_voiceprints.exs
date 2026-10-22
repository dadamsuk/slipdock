defmodule Slipdock.Repo.Migrations.AddTranscriptionVoiceprints do
  use Ecto.Migration

  # Whether naming a voice in a transcript teaches the transcription server
  # that voice (#1201): off until an admin turns it on.
  def change do
    alter table(:settings) do
      add :transcription_voiceprints, :boolean, null: false, default: false
    end
  end
end
