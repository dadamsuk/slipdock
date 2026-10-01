defmodule Slipdock.Boards.Activity do
  use Ecto.Schema

  schema "activities" do
    field :kind, :string
    field :message, :string
    belongs_to :board, Slipdock.Boards.Board
    belongs_to :card, Slipdock.Boards.Card
    # Set when the entry is about a wiki page rather than a card.
    belongs_to :page, Slipdock.Wiki.Page
    timestamps(type: :utc_datetime, updated_at: false)
  end
end
