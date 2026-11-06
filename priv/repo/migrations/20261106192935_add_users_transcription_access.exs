defmodule Slipdock.Repo.Migrations.AddUsersTranscriptionAccess do
  @moduledoc """
  Who may transcribe a card's recording and teach the transcription server a
  voice gets a column of its own, `users.transcription_access` (#1817). It
  starts as `meetings_access` was; that column goes with meeting capture.
  """
  use Ecto.Migration

  def up do
    alter table(:users) do
      add :transcription_access, :boolean, null: false, default: false
    end

    flush()

    execute copy()
  end

  @doc false
  # Everybody who had meetings has transcription. A test runs it again.
  def copy, do: "UPDATE users SET transcription_access = TRUE WHERE meetings_access"

  def down do
    alter table(:users) do
      remove :transcription_access
    end
  end
end
