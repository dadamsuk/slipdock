defmodule Slipdock.Wiki.Placement do
  @moduledoc """
  A page *also filed in* a folder other than its home (`Slipdock.Wiki.Page`'s
  `folder_id`): a placement, like a symbolic link. The page is not copied —
  there is one body and one history — it is simply found in one more place
  (see `Slipdock.Wiki.Placements`).
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "page_placements" do
    field :position, :integer, default: 0

    belongs_to :page, Slipdock.Wiki.Page
    belongs_to :folder, Slipdock.Wiki.Folder

    timestamps(type: :utc_datetime)
  end

  def changeset(placement, attrs) do
    placement
    |> cast(attrs, [:page_id, :folder_id, :position])
    |> validate_required([:page_id, :folder_id])
    |> unique_constraint([:page_id, :folder_id],
      name: :page_placements_page_id_folder_id_index,
      message: "the page is already filed there"
    )
  end
end
