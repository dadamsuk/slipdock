defmodule Slipdock.TransferLinks.Link do
  @moduledoc """
  One short-lived, single-use URL (#1147): an upload to a card or a page, or
  a download of one attachment. Only the hash of the secret in the URL is
  kept, as an API token's is.
  """
  use Ecto.Schema

  schema "transfer_links" do
    field :token_hash, :binary, redact: true
    field :kind, :string
    field :expires_at, :utc_datetime
    field :used_at, :utc_datetime

    belongs_to :user, Slipdock.Accounts.User
    belongs_to :user_token, Slipdock.Accounts.UserToken
    belongs_to :card, Slipdock.Boards.Card
    belongs_to :page, Slipdock.Wiki.Page
    belongs_to :attachment, Slipdock.Boards.Attachment

    timestamps(type: :utc_datetime, updated_at: false)
  end
end
