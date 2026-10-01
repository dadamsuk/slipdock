defmodule Slipdock.Boards.Attachment do
  @moduledoc """
  A file attached to a card or to a wiki page: an explicit upload, or an
  image pasted into a description, a comment or a page body. The bytes live
  on disk under the uploads directory at `key`; the row keeps the original
  name, type and size.

  Exactly one of `card_id` and `page_id` is set — a file belongs to one thing,
  and the database enforces it.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @image_types ~w(image/png image/jpeg image/gif image/webp)
  @max_size 25 * 1024 * 1024

  schema "attachments" do
    field :filename, :string
    field :content_type, :string
    field :size, :integer
    field :key, :string
    belongs_to :card, Slipdock.Boards.Card
    belongs_to :page, Slipdock.Wiki.Page
    timestamps(type: :utc_datetime)
  end

  def max_size, do: @max_size
  def image_types, do: @image_types

  @doc "Whether the browser can safely show the file inline (raster images only)."
  def image?(%__MODULE__{content_type: type}), do: type in @image_types

  def changeset(attachment, attrs) do
    attachment
    |> cast(attrs, [:filename, :content_type, :size, :key, :card_id, :page_id])
    |> update_change(:filename, &clean_filename/1)
    |> update_change(:content_type, &clean_content_type/1)
    |> validate_required([:filename, :content_type, :size, :key])
    |> Slipdock.Boards.Owned.validate_owner()
    |> validate_length(:filename, min: 1, max: 255)
    |> validate_number(:size, greater_than: 0, less_than_or_equal_to: @max_size)
    |> unique_constraint(:key)
  end

  @doc "What this file hangs off."
  defdelegate owner(attachment), to: Slipdock.Boards.Owned

  # Keep only the base name, and never an empty one.
  defp clean_filename(name) when is_binary(name) do
    case name |> String.trim() |> Path.basename() do
      "" -> "file"
      "." -> "file"
      ".." -> "file"
      base -> base
    end
  end

  defp clean_filename(other), do: other

  defp clean_content_type(type) when is_binary(type) do
    case type |> String.trim() |> String.downcase() do
      "" -> "application/octet-stream"
      t -> if String.contains?(t, "/"), do: t, else: "application/octet-stream"
    end
  end

  defp clean_content_type(other), do: other

  @doc "A short label for the file's kind, used for icons."
  def kind(%__MODULE__{} = a) do
    cond do
      image?(a) -> :image
      a.content_type == "application/pdf" -> :pdf
      String.starts_with?(a.content_type, "text/") -> :text
      String.contains?(a.content_type, ["zip", "compressed", "tar"]) -> :archive
      String.contains?(a.content_type, ["spreadsheet", "excel", "csv"]) -> :sheet
      String.contains?(a.content_type, ["word", "document", "presentation"]) -> :doc
      true -> :file
    end
  end
end
