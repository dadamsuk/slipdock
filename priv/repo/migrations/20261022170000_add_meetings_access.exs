defmodule Slipdock.Repo.Migrations.AddMeetingsAccess do
  use Ecto.Migration

  # Meetings, transcription and voiceprints are for the people an admin turns
  # them on for (#1206); admins always have them. Somebody who already owns a
  # meeting capture keeps the feature, so nobody loses what they started.
  def up do
    alter table(:users) do
      add :meetings_access, :boolean, default: false, null: false
    end

    flush()

    execute """
    UPDATE users SET meetings_access = TRUE
    WHERE id IN (SELECT owner_id FROM captures WHERE kind = 'meeting' AND owner_id IS NOT NULL)
    """
  end

  def down do
    alter table(:users) do
      remove :meetings_access
    end
  end
end
