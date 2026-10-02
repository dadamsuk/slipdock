defmodule Slipdock.Repo.Migrations.SupportAccess do
  use Ecto.Migration

  # An admin looking at somebody's boards to help them. Time-limited, and
  # recorded where the person it is about can read it — which is the only thing
  # that makes it different from a quiet superpower.
  def change do
    create table(:support_sessions) do
      # Whose data. Not "who asked for help": an admin may be reacting to a
      # report from somebody else entirely.
      add :subject_id, references(:users, on_delete: :delete_all), null: false
      add :admin_id, references(:users, on_delete: :nilify_all), null: false
      # Why. Required, because "because I could" should be hard to write down.
      add :reason, :string, null: false
      add :expires_at, :utc_datetime, null: false
      add :ended_at, :utc_datetime

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:support_sessions, [:subject_id])
    create index(:support_sessions, [:admin_id])
    create index(:support_sessions, [:expires_at])
  end
end
