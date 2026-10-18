defmodule Slipdock.Repo.Migrations.AddCaptureKeepTranscript do
  use Ecto.Migration

  # #1077: a capture may drop its transcript once committed, keeping only the
  # quoted evidence; and a card's trail says whether it came from a meeting
  # or a conversation.
  def change do
    alter table(:captures) do
      add :keep_transcript, :boolean, null: false, default: true
      add :transcript_dropped_at, :utc_datetime
    end

    alter table(:card_provenance) do
      add :source, :string, null: false, default: "meeting"
    end
  end
end
