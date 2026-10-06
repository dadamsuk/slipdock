defmodule Slipdock.Repo.Migrations.CreateOauthClients do
  use Ecto.Migration

  # Third-party apps that registered themselves through OAuth dynamic client
  # registration (RFC 7591). Anybody may register one, so a row here grants
  # nothing by itself: it is the name and the redirect addresses that a person
  # is later shown and asked to approve.
  def change do
    create table(:oauth_clients) do
      add :client_id, :string, null: false
      add :client_name, :string
      add :redirect_uris, {:array, :text}, null: false, default: []
      add :registered_ip, :string
      timestamps(type: :utc_datetime)
    end

    create unique_index(:oauth_clients, [:client_id])
    create index(:oauth_clients, [:inserted_at])
  end
end
