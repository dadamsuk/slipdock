defmodule Slipdock.Wiki.FolderPlacement do
  @moduledoc """
  A folder *also filed in* a folder other than its home (`Slipdock.Wiki.Folder`'s
  `parent_id`): a placement, like a symbolic link. The folder is not copied —
  there is one folder with one set of contents — it is simply found in one
  more place, with everything under it (see `Slipdock.Wiki.FolderPlacements`).
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "folder_placements" do
    field :position, :integer, default: 0

    belongs_to :folder, Slipdock.Wiki.Folder
    belongs_to :in_folder, Slipdock.Wiki.Folder

    timestamps(type: :utc_datetime)
  end

  def changeset(placement, attrs) do
    placement
    |> cast(attrs, [:folder_id, :in_folder_id, :position])
    |> validate_required([:folder_id, :in_folder_id])
    |> unique_constraint([:folder_id, :in_folder_id],
      name: :folder_placements_folder_id_in_folder_id_index,
      message: "the folder is already filed there"
    )
  end
end
