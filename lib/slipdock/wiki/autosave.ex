defmodule Slipdock.Wiki.Autosave do
  @moduledoc """
  One person's unsaved work in the wiki's editor (#1532): the form as it last
  stood. `page_id` is the page being edited, or nil for a page that does not
  exist yet. Nobody else ever sees it. See `Slipdock.Wiki.Autosaves`.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "page_autosaves" do
    # The form's fields, as `Wiki.change_page/2` takes them, and for a new
    # page where it was started: `parent_id` and `column_id`.
    field :attrs, :map, default: %{}
    # The hash the editor opened against: a restored edit still meets the
    # conflict check, however long ago it was typed.
    field :base_hash, :string
    belongs_to :user, Slipdock.Accounts.User
    belongs_to :board, Slipdock.Boards.Board
    belongs_to :page, Slipdock.Wiki.Page
    has_many :files, Slipdock.Wiki.AutosaveFile
    timestamps(type: :utc_datetime)
  end

  def changeset(autosave, attrs) do
    autosave
    |> cast(attrs, [:attrs, :base_hash])
    |> foreign_key_constraint(:page_id)
    |> foreign_key_constraint(:board_id)
  end

  @doc "What it is called in a list: its title, or a stand-in until it has one."
  def title(%__MODULE__{attrs: attrs}) do
    case String.trim(attrs["title"] || "") do
      "" -> "Untitled page"
      title -> title
    end
  end
end
