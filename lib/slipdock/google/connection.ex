defmodule Slipdock.Google.Connection do
  @moduledoc """
  A person's Google Drive connection: the refresh token Google gave when they
  agreed to `drive.readonly`, the access token it last traded for, and the
  address they connected as. Both tokens are stored encrypted (see
  `Slipdock.Google.encrypt/1`); `revoked_at` is set when Google refuses the
  refresh token, and the account page then shows the connection as gone.
  """
  use Ecto.Schema

  schema "google_connections" do
    field :email, :string
    field :refresh_token, :string, redact: true
    field :access_token, :string, redact: true
    field :access_expires_at, :utc_datetime
    field :revoked_at, :utc_datetime

    belongs_to :user, Slipdock.Accounts.User

    timestamps(type: :utc_datetime)
  end
end
