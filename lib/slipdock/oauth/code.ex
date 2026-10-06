defmodule Slipdock.OAuth.Code do
  @moduledoc """
  An authorization code: what a person's approval turns into, and what the
  client trades for a token at `/oauth/token`.

  Short-lived (a minute), good once, stored hashed, and bound to everything
  the approval was given for — the client, the exact redirect URI, the PKCE
  challenge, the scope and the resource — so a code that leaks on its way
  back to the client is no use to anybody without the verifier.
  """
  use Ecto.Schema

  schema "oauth_codes" do
    field :code_hash, :binary, redact: true
    field :redirect_uri, :string
    field :code_challenge, :string
    field :scope, :string
    field :resource, :string
    field :expires_at, :utc_datetime
    field :used_at, :utc_datetime
    field :token_id, :id
    belongs_to :client, Slipdock.OAuth.Client
    belongs_to :user, Slipdock.Accounts.User
    timestamps(type: :utc_datetime, updated_at: false)
  end
end
