defmodule Slipdock.Repo.Migrations.AddMeetingTranscriptionToSettings do
  use Ecto.Migration

  def change do
    # Who turns a recording into words: nobody ("none"), the sender's own AI
    # provider (OpenRouter, or their endpoint), or an endpoint of the admin's.
    alter table(:settings) do
      add :meetings_transcription, :string, default: "none", null: false
      add :meetings_transcription_model, :string, default: "openai/whisper-large-v3"
      add :meetings_transcription_url, :string
      add :meetings_transcription_max_mb, :integer, default: 25
    end
  end
end
