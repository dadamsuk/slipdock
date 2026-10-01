defmodule Slipdock.Boards.Comment do
  @moduledoc """
  A remark on a card or on a wiki page. Exactly one of `card_id` and
  `page_id` is set; see `Slipdock.Boards.Owned`.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "comments" do
    field :body, :string
    belongs_to :card, Slipdock.Boards.Card
    belongs_to :page, Slipdock.Wiki.Page
    timestamps(type: :utc_datetime)
  end

  def changeset(comment, attrs) do
    comment
    |> cast(attrs, [:body, :card_id, :page_id])
    |> validate_required([:body])
    |> Slipdock.Boards.Owned.validate_owner()
    |> validate_length(:body, min: 1, max: 250_000)
  end
end
