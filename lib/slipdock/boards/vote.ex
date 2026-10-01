defmodule Slipdock.Boards.Vote do
  @moduledoc """
  Budget voting: how many of their votes one person has put on a card, or on
  a wiki page. Exactly one of `card_id` and `page_id` is set; see
  `Slipdock.Boards.Owned`.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "votes" do
    field :count, :integer, default: 1
    field :comment, :string

    belongs_to :card, Slipdock.Boards.Card
    belongs_to :page, Slipdock.Wiki.Page
    belongs_to :user, Slipdock.Accounts.User

    timestamps(type: :utc_datetime)
  end

  def changeset(vote, attrs) do
    vote
    |> cast(attrs, [:count, :comment, :card_id, :page_id])
    |> validate_required([:count])
    |> Slipdock.Boards.Owned.validate_owner()
    |> validate_number(:count, greater_than_or_equal_to: 0)
    |> validate_length(:comment, max: 500)
  end
end
