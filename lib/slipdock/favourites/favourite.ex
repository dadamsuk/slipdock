defmodule Slipdock.Favourites.Favourite do
  @moduledoc """
  One favourite: a person marked one thing — a board, a list, a card, a saved
  view or a wiki page — as somewhere they go often.

  The shape is `Slipdock.Access.Grant`'s: exactly one resource per row. It is
  the person's own, so nothing here is shared; two people favouriting the
  same card have a row each.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @kinds [:board, :column, :card, :view, :page]

  schema "favourites" do
    belongs_to :user, Slipdock.Accounts.User
    belongs_to :board, Slipdock.Boards.Board
    belongs_to :column, Slipdock.Boards.Column
    belongs_to :card, Slipdock.Boards.Card
    belongs_to :saved_view, Slipdock.Boards.SavedView
    belongs_to :page, Slipdock.Wiki.Page
    timestamps(type: :utc_datetime)
  end

  @doc "The kinds of thing that can be favourited."
  def kinds, do: @kinds

  def changeset(favourite, attrs) do
    favourite
    |> cast(attrs, [:user_id, :board_id, :column_id, :card_id, :saved_view_id, :page_id])
    |> validate_required([:user_id])
    |> validate_one_resource()
    |> unique_constraint([:user_id, :board_id])
    |> unique_constraint([:user_id, :column_id])
    |> unique_constraint([:user_id, :card_id])
    |> unique_constraint([:user_id, :saved_view_id])
    |> unique_constraint([:user_id, :page_id])
  end

  defp validate_one_resource(changeset) do
    fields = [:board_id, :column_id, :card_id, :saved_view_id, :page_id]
    set = Enum.count(fields, &(not is_nil(get_field(changeset, &1))))

    if set == 1,
      do: changeset,
      else: add_error(changeset, :board_id, "exactly one resource must be set")
  end

  @doc "Which kind of thing this row points at."
  def kind(%__MODULE__{board_id: id}) when not is_nil(id), do: :board
  def kind(%__MODULE__{column_id: id}) when not is_nil(id), do: :column
  def kind(%__MODULE__{card_id: id}) when not is_nil(id), do: :card
  def kind(%__MODULE__{page_id: id}) when not is_nil(id), do: :page
  def kind(%__MODULE__{}), do: :view

  @doc "The id of the thing this row points at."
  def resource_id(%__MODULE__{} = f) do
    case kind(f) do
      :board -> f.board_id
      :column -> f.column_id
      :card -> f.card_id
      :view -> f.saved_view_id
      :page -> f.page_id
    end
  end

  @doc "The column this kind of favourite is stored in."
  def field(:board), do: :board_id
  def field(:column), do: :column_id
  def field(:card), do: :card_id
  def field(:view), do: :saved_view_id
  def field(:page), do: :page_id
end
