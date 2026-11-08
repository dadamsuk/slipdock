defmodule Slipdock.Work.Dismissal do
  @moduledoc """
  One item a person took off their own Waiting on you (#2069): the card and
  the cause it was there for (`Slipdock.Work.waiting_on_me/2`'s `cause`).
  The same cause stays off; a new one on the same card shows again.
  """
  use Ecto.Schema

  schema "waiting_dismissals" do
    belongs_to :user, Slipdock.Accounts.User
    belongs_to :card, Slipdock.Boards.Card
    field :reason, :string
    field :cause, :string
    timestamps(type: :utc_datetime, updated_at: false)
  end
end
