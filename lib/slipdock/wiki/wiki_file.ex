defmodule Slipdock.Wiki.WikiFile do
  @moduledoc """
  A file in a board's wiki that is not a page: an image, a PDF, a drawing,
  kept where a synced vault keeps it (W-103 R2.9). It is filed like a page —
  in a folder, or at the wiki's root — rather than hanging off one page the
  way an attachment does, so `![[diagram.png]]` finds it from any note.

  The bytes live under the uploads directory at `key`; `sha256` is their
  hash, which is what a sync compares.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "wiki_files" do
    field :name, :string
    field :content_type, :string
    field :size, :integer
    field :sha256, :string
    field :key, :string
    field :archived_at, :utc_datetime

    belongs_to :board, Slipdock.Boards.Board
    belongs_to :folder, Slipdock.Wiki.Folder
    belongs_to :created_by, Slipdock.Accounts.User

    timestamps(type: :utc_datetime)
  end

  @image_types ~w(image/png image/jpeg image/gif image/webp)

  def changeset(file, attrs) do
    file
    |> cast(attrs, [:name, :content_type, :size, :sha256, :key, :folder_id, :archived_at])
    |> update_change(:name, &clean_name/1)
    |> validate_required([:name, :content_type, :size, :sha256, :key])
    |> validate_length(:name, min: 1, max: 255)
    |> validate_number(:size,
      greater_than_or_equal_to: 0,
      less_than_or_equal_to: Slipdock.Boards.Attachment.max_size()
    )
    |> unique_constraint(:key)
  end

  # A name is one path segment: no slashes, nothing that climbs.
  defp clean_name(name) do
    name
    |> to_string()
    |> String.replace(~r/[\/\\]+/, "-")
    |> String.trim()
    |> String.replace(~r/^\.+/, "-")
  end

  @doc "Whether the browser can show it inline (raster images only, never SVG)."
  def image?(%__MODULE__{content_type: type}), do: type in @image_types

  @doc "The content type a name implies, for what a sync sends without one."
  def content_type(name) do
    case name |> Path.extname() |> String.downcase() do
      ".png" -> "image/png"
      ".jpg" -> "image/jpeg"
      ".jpeg" -> "image/jpeg"
      ".gif" -> "image/gif"
      ".webp" -> "image/webp"
      ".svg" -> "image/svg+xml"
      ".pdf" -> "application/pdf"
      ".excalidraw" -> "application/json"
      ".json" -> "application/json"
      ".txt" -> "text/plain"
      ".csv" -> "text/csv"
      ".mp3" -> "audio/mpeg"
      ".m4a" -> "audio/mp4"
      ".wav" -> "audio/wav"
      ".mp4" -> "video/mp4"
      _ -> "application/octet-stream"
    end
  end
end
