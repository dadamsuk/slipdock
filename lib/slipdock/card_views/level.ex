defmodule Slipdock.CardViews.Level do
  @moduledoc """
  One person's card view at one level (#2031): global (no board), a board, or
  one list on it. It can apply a named card view (`card_view`) and state its
  own elements on top (`elements`, only what it changes). `show_all` is the
  board's Show all switch, so only a board's level sets it.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Slipdock.CardViews.CardView

  schema "card_view_levels" do
    field :elements, :map, default: %{}
    field :show_all, :boolean, default: false
    belongs_to :user, Slipdock.Accounts.User
    belongs_to :board, Slipdock.Boards.Board
    belongs_to :column, Slipdock.Boards.Column
    belongs_to :card_view, CardView
    timestamps(type: :utc_datetime)
  end

  def changeset(level, attrs) do
    level
    |> cast(attrs, [:elements, :show_all, :card_view_id])
    |> CardView.validate_elements(:elements)
  end

  @doc "Whether the level states nothing at all, so its row can go."
  def empty?(%__MODULE__{elements: elements, show_all: show_all, card_view_id: id}),
    do: elements == %{} and not show_all and is_nil(id)
end
