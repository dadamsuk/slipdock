defmodule Slipdock.Repo.Migrations.CreateVoiceprints do
  use Ecto.Migration

  def change do
    # Voiceprints (see `Slipdock.Meetings.Voiceprints`): off unless an admin
    # turns them on, and then only for whoever opts in.
    alter table(:settings) do
      add :meetings_voiceprints, :boolean, default: false, null: false
      add :meetings_voiceprint_url, :string
    end

    # One per person at most: the embedding only, never the audio it came from.
    create table(:voiceprints) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :embedding, {:array, :float}, null: false
      add :source, :string, null: false
      add :source_capture_id, references(:captures, on_delete: :nilify_all)
      add :consent_version, :string, null: false
      add :consented_at, :utc_datetime, null: false
      timestamps(type: :utc_datetime)
    end

    create unique_index(:voiceprints, [:user_id])

    # Consent given and withdrawn: who, when, and the wording they saw. Kept
    # when the voiceprint is deleted, so the record says it was.
    create table(:voiceprint_consents) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :event, :string, null: false
      add :wording_version, :string, null: false
      add :wording, :text, null: false
      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:voiceprint_consents, [:user_id])
  end
end
