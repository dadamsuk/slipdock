defmodule Slipdock.Boards.SavedView do
  @moduledoc """
  A named swimlane configuration saved against a board. `config` is the
  string-keyed map produced by `Slipdock.Swimlanes.Config.to_map/1`.

  Whether a view is a favourite is not the view's business: favourites
  belong to the person who marked them (see `Slipdock.Favourites`), and the
  view switcher lists the reader's own.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "saved_views" do
    field :name, :string
    field :config, :map, default: %{}
    # Set when the view is published: anyone with the token can read it.
    field :public_token, :string
    belongs_to :board, Slipdock.Boards.Board
    timestamps(type: :utc_datetime)
  end

  def changeset(view, attrs) do
    view
    |> cast(attrs, [:name, :config, :board_id])
    |> validate_required([:name, :config, :board_id])
    |> update_change(:name, &String.trim/1)
    |> validate_length(:name, min: 1, max: 60)
    |> unique_constraint([:board_id, :name],
      error_key: :name,
      message: "already exists on this board"
    )
  end
end
