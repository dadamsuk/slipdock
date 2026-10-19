defmodule Slipdock.TransferLinks.Link do
  @moduledoc """
  One short-lived, single-use URL (#1147): an upload to a card or a page, or
  a download of one attachment, or of a Tool version's skills archive, one
  skill's zip or one file (#1158). Only the hash of the secret in the URL is
  kept, as an API token's is.
  """
  use Ecto.Schema

  schema "transfer_links" do
    field :token_hash, :binary, redact: true
    field :kind, :string
    field :expires_at, :utc_datetime
    field :used_at, :utc_datetime
    # With `tool_version`: "archive", "claude:<skill>" or "file:<path>".
    field :tool_target, :string

    belongs_to :user, Slipdock.Accounts.User
    belongs_to :user_token, Slipdock.Accounts.UserToken
    belongs_to :card, Slipdock.Boards.Card
    belongs_to :page, Slipdock.Wiki.Page
    belongs_to :attachment, Slipdock.Boards.Attachment
    belongs_to :tool_version, Slipdock.Tools.Version

    timestamps(type: :utc_datetime, updated_at: false)
  end
end
