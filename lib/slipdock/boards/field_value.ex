defmodule Slipdock.Boards.FieldValue do
  @moduledoc """
  A card's — or a wiki page's — value for one custom field; which column is
  used depends on the field's kind. Exactly one of `card_id` and `page_id` is
  set; see `Slipdock.Boards.Owned`.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "card_field_values" do
    field :number, :float
    field :text, :string
    field :date, :date
    field :option, :string

    belongs_to :card, Slipdock.Boards.Card
    belongs_to :page, Slipdock.Wiki.Page
    belongs_to :field, Slipdock.Boards.FieldDefinition

    timestamps(type: :utc_datetime)
  end

  def changeset(value, attrs) do
    value
    |> cast(attrs, [:number, :text, :date, :option, :card_id, :page_id, :field_id])
    |> Slipdock.Boards.Owned.validate_owner()
    |> validate_length(:text, max: 2000)
  end

  @doc "The stored value, whichever column holds it."
  def get(%__MODULE__{number: n}) when is_number(n), do: n
  def get(%__MODULE__{option: o}) when is_binary(o), do: o
  def get(%__MODULE__{date: %Date{} = d}), do: d
  def get(%__MODULE__{text: t}) when is_binary(t), do: t
  def get(_), do: nil
end
