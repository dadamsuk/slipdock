defmodule Slipdock.Repo.Migrations.AddChatCaptureEnabled do
  use Ecto.Migration

  # Chat capture's own gate (#1075): on unless an admin turns it off, since a
  # conversation involves no recordings, voiceprints or attendees' consent.
  def change do
    alter table(:settings) do
      add :chat_capture_enabled, :boolean, null: false, default: true
    end
  end
end
