defmodule Slipdock.Wiki.AutosaveFile do
  @moduledoc """
  An image pasted into a page that has not been saved yet (#1532), held in the
  uploads directory's `autosaves/` folder until the page exists and it becomes
  an ordinary attachment.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Slipdock.Boards.Attachment

  schema "page_autosave_files" do
    field :filename, :string
    field :content_type, :string
    field :size, :integer
    field :key, :string
    belongs_to :autosave, Slipdock.Wiki.Autosave
    timestamps(type: :utc_datetime)
  end

  def changeset(file, attrs) do
    file
    |> cast(attrs, [:filename, :content_type, :size, :key])
    |> update_change(:filename, &Path.basename/1)
    |> validate_required([:filename, :content_type, :size, :key])
    |> validate_length(:filename, max: 255)
    |> validate_number(:size, greater_than: 0, less_than_or_equal_to: Attachment.image_max_size())
    # Held files are served inline, so only what is safe to show inline.
    |> validate_inclusion(:content_type, Attachment.image_types())
    |> unique_constraint(:key)
  end
end
