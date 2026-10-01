defmodule Slipdock.Boards.ChecklistItem do
  @moduledoc """
  One tick box on a card or on a wiki page. Exactly one of `card_id` and
  `page_id` is set; see `Slipdock.Boards.Owned`.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "checklist_items" do
    field :text, :string
    field :done, :boolean, default: false
    field :position, :integer, default: 0
    belongs_to :card, Slipdock.Boards.Card
    belongs_to :page, Slipdock.Wiki.Page
    timestamps(type: :utc_datetime)
  end

  def changeset(item, attrs) do
    item
    |> cast(attrs, [:text, :done, :position, :card_id, :page_id])
    |> validate_required([:text])
    |> Slipdock.Boards.Owned.validate_owner()
    |> validate_length(:text, min: 1, max: 200)
  end
end
