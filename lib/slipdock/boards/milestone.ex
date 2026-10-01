defmodule Slipdock.Boards.Milestone do
  @moduledoc """
  A named date on a board tree's roadmap: a launch, a conference, a
  deadline. Milestones belong to the root board and are drawn on the
  timeline and calendar of every board in the tree. One can be pinned to a
  card, in which case it is a key date inside that card's plan.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "milestones" do
    field :name, :string
    field :date, :date
    field :color, :string

    belongs_to :board, Slipdock.Boards.Board
    belongs_to :card, Slipdock.Boards.Card

    timestamps(type: :utc_datetime)
  end

  def changeset(milestone, attrs) do
    milestone
    |> cast(attrs, [:name, :date, :color, :card_id])
    |> update_change(:name, &String.trim/1)
    |> update_change(:color, fn
      "" -> nil
      c -> c
    end)
    |> validate_required([:name, :date])
    |> validate_length(:name, min: 1, max: 80)
    |> validate_inclusion(:color, [nil | Slipdock.Palette.names()])
  end
end
