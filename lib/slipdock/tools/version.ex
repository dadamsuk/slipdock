defmodule Slipdock.Tools.Version do
  @moduledoc """
  One published version of a Tool. Immutable: nothing updates a row once it
  is in, and `sha` is a digest over every file in it (see
  `Slipdock.Tools.Package.sha/1`), so two people looking at "1.2.0" are
  looking at the same bytes.

  `manifest` is the package's `tool.json`, `readme` its `README.md`, and
  `board` its validated `board.json` blueprint (nil when it has none). The
  files are `Slipdock.Tools.File` rows.
  """
  use Ecto.Schema

  schema "tool_versions" do
    field :version, :string
    field :sha, :string
    field :manifest, :map, default: %{}
    field :readme, :string, default: ""
    field :board, :map
    field :size, :integer, default: 0
    belongs_to :tool, Slipdock.Tools.Tool
    belongs_to :published_by, Slipdock.Accounts.User
    has_many :files, Slipdock.Tools.File, preload_order: [asc: :path]
    timestamps(type: :utc_datetime, updated_at: false)
  end
end
