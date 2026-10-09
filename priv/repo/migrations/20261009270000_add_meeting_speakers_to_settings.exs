defmodule Slipdock.Repo.Migrations.AddMeetingSpeakersToSettings do
  use Ecto.Migration

  def change do
    # How voices are separated (the transcript's labels, or a diarisation
    # endpoint) and whether who-is-who may be inferred from the dialogue.
    alter table(:settings) do
      add :meetings_diarisation, :string, default: "labels", null: false
      add :meetings_diarisation_url, :string
      add :meetings_dialogue_inference, :boolean, default: true, null: false
    end

    # How sure the attribution of a voice is: "sure", "confirm" (one weak
    # signal: please confirm), "unknown", or "confirmed" by a person.
    alter table(:capture_voices) do
      add :confidence, :string, null: false, default: "unknown"
    end
  end
end
