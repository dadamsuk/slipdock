defmodule Slipdock.Multiboard.Saved do
  @moduledoc """
  A saved multiboard (#1482): a Multiboard view (see `Slipdock.Multiboard`)
  kept under a name and a colour, and listed as a tile on its owner's home
  page among their boards and vaults.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @name_length 80

  schema "saved_multiboards" do
    field :name, :string
    field :color, :string, default: "indigo"
    # Where its owner has put it among their boards on the home page, in the
    # same numbering as their board orders and vaults' places (see
    # `Slipdock.Boards.reorder_boards/2`); nil until it has been placed.
    field :position, :integer
    field :lists, {:array, :integer}, default: []
    field :top, :integer, default: 5
    field :by, :string, default: "board"

    belongs_to :user, Slipdock.Accounts.User

    timestamps(type: :utc_datetime)
  end

  def name_length, do: @name_length

  @doc "The name and colour; the view goes through `view_changeset/2`."
  def changeset(saved, attrs) do
    saved
    |> cast(attrs, [:name, :color])
    |> update_change(:name, &String.trim/1)
    |> validate_required([:name])
    |> validate_length(:name, min: 1, max: @name_length)
    |> validate_inclusion(:color, Slipdock.Palette.names())
  end

  @doc "The view it shows: `%{lists, top, by}`, already normalized."
  def view_changeset(saved, %{lists: lists, top: top, by: by}),
    do: change(saved, lists: lists, top: top, by: by)

  @doc "The view it shows, in the shape `Slipdock.Multiboard` works with."
  def view(%__MODULE__{lists: lists, top: top, by: by}), do: %{lists: lists, top: top, by: by}
end
