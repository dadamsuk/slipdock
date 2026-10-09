defmodule Slipdock.Meetings.Event do
  @moduledoc """
  One line of a capture's record: received, read, dropped, answered,
  committed, undone. Never edited; a question answered twice has two lines.
  """
  use Ecto.Schema

  schema "capture_events" do
    belongs_to :capture, Slipdock.Meetings.Capture
    belongs_to :user, Slipdock.Accounts.User
    field :kind, :string
    field :message, :string
    field :via, :string
    field :data, :map, default: %{}
    field :inserted_at, :utc_datetime_usec
  end
end
