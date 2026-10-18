defmodule Slipdock.Repo.Migrations.AddCaptureKind do
  use Ecto.Migration

  # A capture of a meeting, or of a conversation with an AI assistant (#1074).
  def change do
    alter table(:captures) do
      add :kind, :string, null: false, default: "meeting"
    end
  end
end
