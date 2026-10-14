defmodule Slipdock.Wiki.Folder do
  @moduledoc """
  A folder on a board's wiki: a name, a place in a tree of folders, and the
  pages filed in it.

  Folders are filing, and filing only. They carry no prose, no permissions of
  their own and no history — a folder is where something is kept, and the
  thing kept is the page. That is what keeps them different from a page with
  children, which says the child is *part of* the parent (see
  `Slipdock.Wiki.Page`).

  `slug` is unique per board rather than per parent, so `design` names one
  folder on a board however deep it sits, and `folder("QVM", "design")`
  from the CLI has one answer. A clash gets a number appended, exactly as a
  page's does.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @name_length 120

  schema "page_folders" do
    field :name, :string
    field :slug, :string
    field :position, :integer, default: 0
    # How the tree orders the pages in it (W-103 R11.9): see `sorts/0`. nil
    # follows the board's `wiki_sort` (#789).
    field :sort, :string

    belongs_to :board, Slipdock.Boards.Board
    belongs_to :parent, __MODULE__

    has_many :children, __MODULE__, foreign_key: :parent_id, preload_order: [asc: :position]
    has_many :pages, Slipdock.Wiki.Page, preload_order: [asc: :position]

    timestamps(type: :utc_datetime)
  end

  def name_length, do: @name_length

  @sorts ~w(manual name modified created)

  @doc """
  The orders a folder's pages can be shown in: as dragged, by name, newest
  change first, or newest first. Folders always come before pages. A folder
  given `"board"` (or nil) has no order of its own and follows the board's.
  """
  def sorts, do: @sorts

  def changeset(folder, attrs) do
    folder
    |> cast(attrs, [:name, :slug, :position, :parent_id, :sort])
    |> update_change(:sort, &if(&1 == "board", do: nil, else: &1))
    |> validate_inclusion(:sort, @sorts)
    |> update_change(:name, &String.trim/1)
    |> update_change(:slug, &sanitize_slug/1)
    |> validate_required([:name])
    |> validate_length(:name, min: 1, max: @name_length)
    |> validate_length(:slug, min: 1, max: @name_length)
    |> unique_constraint([:board_id, :slug],
      name: :page_folders_board_id_slug_index,
      message: "there is already a folder with that name on this board"
    )
  end

  @doc "The shape a folder's slug takes — a page's rules, so the two read alike."
  defdelegate sanitize_slug(value), to: Slipdock.Wiki.Page

  @doc "A free slug for `name` on a board, given what is taken."
  defdelegate slug_from_name(name, taken), to: Slipdock.Wiki.Page, as: :slug_from_title
end
