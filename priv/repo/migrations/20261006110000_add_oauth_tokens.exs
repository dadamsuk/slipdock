defmodule Slipdock.Repo.Migrations.AddOauthTokens do
  use Ecto.Migration

  # An OAuth connection is one ordinary API token (W-21 §5): the access token
  # is the row's own token, expiring in an hour, and the refresh token that
  # renews it lives on the same row. Deleting the row under Account → API
  # tokens ends both at once.
  #
  # Authorization codes get a table of their own: they are bound to a client,
  # a redirect URI and a PKCE challenge, which is nothing like a token row.
  def change do
    alter table(:users_tokens) do
      add :oauth_client_id, references(:oauth_clients, on_delete: :delete_all)
      add :refresh_token_hash, :binary
      add :refresh_expires_at, :utc_datetime
    end

    create index(:users_tokens, [:oauth_client_id])
    create unique_index(:users_tokens, [:refresh_token_hash])

    create table(:oauth_codes) do
      add :code_hash, :binary, null: false
      add :client_id, references(:oauth_clients, on_delete: :delete_all), null: false
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :redirect_uri, :text, null: false
      add :code_challenge, :string, null: false
      add :scope, :string, null: false
      add :resource, :text
      add :expires_at, :utc_datetime, null: false
      add :used_at, :utc_datetime
      # The token a code was exchanged for, so a code presented twice can take
      # that token back with it (RFC 6749 §4.1.2).
      add :token_id, references(:users_tokens, on_delete: :nilify_all)
      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:oauth_codes, [:code_hash])
    create index(:oauth_codes, [:expires_at])
  end
end
