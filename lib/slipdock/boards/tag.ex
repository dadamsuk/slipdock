defmodule Slipdock.Boards.Tag do
  use Ecto.Schema
  import Ecto.Changeset

  schema "tags" do
    field :name, :string
    field :color, :string, default: "slate"
    belongs_to :board, Slipdock.Boards.Board
    timestamps(type: :utc_datetime)
  end

  def changeset(tag, attrs) do
    tag
    |> cast(attrs, [:name, :color, :board_id])
    |> validate_required([:name, :color, :board_id])
    |> update_change(:name, &String.trim/1)
    |> validate_length(:name, min: 1, max: 30)
    |> validate_inclusion(:color, Slipdock.Palette.names())
    |> unique_constraint([:board_id, :name],
      error_key: :name,
      message: "already exists on this board"
    )
  end
end
