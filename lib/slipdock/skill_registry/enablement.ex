defmodule Slipdock.SkillRegistry.Enablement do
  @moduledoc """
  A registry entry enabled on a board (#2062). It carries the text the
  writer read when they enabled it, or last re-pinned it: `pinned_body` and
  its `pinned_hash`, with the name, description, source, licence and
  version as they were then. That copy is what the board's agents get. When
  the entry's own `content_hash` no longer matches, it has changed upstream;
  when `entry_id` is nil the entry has gone from its source. Either way the
  pinned text is still what is served, until a writer re-pins or disables it.

  The board is always the root of its tree: a sub-board shares its root's
  enabled skills, as it shares its handbook.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "skill_enablements" do
    field :name, :string
    field :description, :string
    field :source_name, :string
    field :source_url, :string
    field :licence, :string
    field :version, :string
    field :pinned_hash, :string
    field :pinned_body, :string
    field :pinned_at, :utc_datetime
    belongs_to :board, Slipdock.Boards.Board
    belongs_to :entry, Slipdock.SkillRegistry.Entry
    belongs_to :enabled_by, Slipdock.Accounts.User
    timestamps(type: :utc_datetime)
  end

  @fields [
    :name,
    :description,
    :source_name,
    :source_url,
    :licence,
    :version,
    :pinned_hash,
    :pinned_body,
    :pinned_at,
    :entry_id,
    :enabled_by_id
  ]

  @doc "The fields a pin sets."
  def changeset(enablement, attrs) do
    enablement
    |> cast(attrs, @fields)
    |> validate_required([:name, :pinned_hash, :pinned_body, :pinned_at])
    |> unique_constraint([:board_id, :name],
      message: "is already enabled on this board"
    )
  end
end
