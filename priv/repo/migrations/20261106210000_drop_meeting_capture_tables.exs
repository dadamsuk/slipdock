defmodule Slipdock.Repo.Migrations.DropMeetingCaptureTables do
  @moduledoc """
  Meeting and chat capture's tables and columns go (W-2330, #1819): its 11
  tables, the `settings` columns that configured it, `users.hide_meetings`,
  `users.meetings_access` and `boards.meetings_used_at`.

  Forward only, and a rollback past it is unsupported: an image from before
  #1819 still reads these columns, so it fails against this schema (W-1951
  §Rollback; a waiver of OPS-6 the card's owner chose).
  """
  use Ecto.Migration

  # Children before the parents they point at.
  @tables ~w(capture_events capture_evidence capture_findings capture_questions
             capture_utterances meeting_usage card_provenance voiceprint_consents
             voiceprints capture_voices captures)a

  @settings_columns ~w(meetings_enabled meetings_visibility meetings_hideable
                       meetings_accept_transcripts meetings_accept_audio
                       meetings_accept_findings meetings_reading_model
                       meetings_second_reading meetings_second_model
                       meetings_transcription_minutes meetings_transcription_minutes_enabled
                       meetings_audio_storage_mb meetings_audio_storage_mb_enabled
                       meetings_transcript_captures meetings_transcript_captures_enabled
                       meetings_longest_minutes meetings_max_file_mb meetings_audio_retention
                       meetings_transcription meetings_transcription_model
                       meetings_transcription_url meetings_transcription_max_mb
                       meetings_diarisation meetings_diarisation_url
                       meetings_dialogue_inference meetings_relisten_model
                       meetings_voiceprints meetings_voiceprint_url chat_capture_enabled)a

  @doc false
  def tables, do: @tables

  @doc false
  def columns do
    [
      settings: @settings_columns,
      users: [:hide_meetings, :meetings_access],
      boards: [:meetings_used_at]
    ]
  end

  def up do
    for table <- @tables, do: execute("DROP TABLE IF EXISTS #{table} CASCADE")

    for {table, cols} <- columns() do
      alter table(table) do
        for col <- cols, do: remove_if_exists(col)
      end
    end
  end

  def down do
    raise Ecto.MigrationError,
      message: "meeting capture's tables and columns were dropped and can't be put back"
  end
end
