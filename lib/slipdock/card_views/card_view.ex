defmodule Slipdock.CardViews.CardView do
  @moduledoc """
  A named card view (#2031): one person's set of elements switched on or off,
  which they can apply at any level (global, a board, a list) or name in a
  saved view. `elements` holds only what it states (`key => true | false`);
  an element it leaves out is inherited from the level below.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Slipdock.CardViews.Elements

  schema "card_views" do
    field :name, :string
    field :elements, :map, default: %{}
    belongs_to :user, Slipdock.Accounts.User
    timestamps(type: :utc_datetime)
  end

  def changeset(view, attrs) do
    view
    |> cast(attrs, [:name, :elements])
    |> update_change(:name, &String.trim/1)
    |> validate_required([:name])
    |> validate_length(:name, min: 1, max: 60)
    |> validate_elements(:elements)
    |> unique_constraint([:user_id, :name],
      error_key: :name,
      message: "you already have a card view of that name"
    )
  end

  @doc "Checks that a map of elements names only known elements, each true or false."
  def validate_elements(changeset, field) do
    validate_change(changeset, field, fn _, elements ->
      bad =
        Enum.reject(elements, fn {key, value} -> Elements.known?(key) and is_boolean(value) end)

      case bad do
        [] -> []
        bad -> [{field, "unknown elements or values: #{Enum.map_join(bad, ", ", &elem(&1, 0))}"}]
      end
    end)
  end
end
