defmodule Slipdock.Repo.Migrations.AddMeetingLimitsToSettings do
  use Ecto.Migration

  def change do
    # Meeting capture's limits, per person per month: each a number and a
    # switch, like the guardrails, so turning one off keeps its number.
    alter table(:settings) do
      add :meetings_transcription_minutes, :integer, default: 600
      add :meetings_transcription_minutes_enabled, :boolean, default: true, null: false
      add :meetings_audio_storage_mb, :integer, default: 2048
      add :meetings_audio_storage_mb_enabled, :boolean, default: true, null: false
      add :meetings_transcript_captures, :integer, default: 200
      add :meetings_transcript_captures_enabled, :boolean, default: true, null: false
      add :meetings_longest_minutes, :integer, default: 240
      add :meetings_max_file_mb, :integer, default: 500
      add :meetings_audio_retention, :string, default: "30_days", null: false
    end
  end
end
