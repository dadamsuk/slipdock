defmodule Slipdock.Inbound.Token do
  @moduledoc """
  The token in an inbound address: a row of `inbound_tokens` (#1244). A
  board token (`board` set) is behind that person's `card-…` and `page-…`
  addresses for the board; a personal one (`board` nil) is behind their
  `add-…` address. At most one of each is live, `revoked_at` nil; rotating
  revokes the old row and makes a new one.
  """
  use Ecto.Schema

  @type t :: %__MODULE__{}

  schema "inbound_tokens" do
    field :token_hash, :binary, redact: true
    field :token_encrypted, :binary, redact: true
    field :rotated_at, :utc_datetime
    field :revoked_at, :utc_datetime
    belongs_to :user, Slipdock.Accounts.User
    belongs_to :board, Slipdock.Boards.Board
    timestamps(type: :utc_datetime, updated_at: false)
  end
end
