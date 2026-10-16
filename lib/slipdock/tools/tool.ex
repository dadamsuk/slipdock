defmodule Slipdock.Tools.Tool do
  @moduledoc """
  A Tool (#958): a named package of docs, files, a board blueprint and agent
  skills that somebody publishes on this server for others to install.

  `slug` is the package's `name` from its `tool.json` and is unique on the
  server: whoever publishes a name first owns it, and every later version of
  it must come from them. The versions are `Slipdock.Tools.Version`s.
  """
  use Ecto.Schema

  schema "tools" do
    field :slug, :string
    field :name, :string
    field :summary, :string
    belongs_to :owner, Slipdock.Accounts.User
    has_many :versions, Slipdock.Tools.Version
    timestamps(type: :utc_datetime)
  end
end
