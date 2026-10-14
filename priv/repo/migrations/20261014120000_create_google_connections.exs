defmodule Slipdock.Repo.Migrations.CreateGoogleConnections do
  use Ecto.Migration

  # A person's Google Drive connection (W-1690): one per user, read-only, its
  # tokens encrypted with a key derived from the secret key base. A vault's
  # recordings are streamed from Drive through its owner's connection.
  def change do
    create table(:google_connections) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :email, :string
      add :refresh_token, :text, null: false
      add :access_token, :text
      add :access_expires_at, :utc_datetime
      add :revoked_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:google_connections, [:user_id])
  end
end
