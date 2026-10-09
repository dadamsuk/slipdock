defmodule Slipdock.Repo.Migrations.AddMeetingMode do
  use Ecto.Migration

  def change do
    alter table(:settings) do
      add :meetings_enabled, :boolean, default: false, null: false
      add :meetings_visibility, :string, default: "used_only", null: false
      add :meetings_hideable, :boolean, default: true, null: false
    end

    alter table(:users) do
      add :hide_meetings, :boolean, default: false, null: false
    end

    # Stamped by a board's first capture, so the board page can tell whether
    # to show its Meetings tab from the row it has already loaded.
    alter table(:boards) do
      add :meetings_used_at, :utc_datetime
    end
  end
end
