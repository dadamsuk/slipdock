defmodule Slipdock.SkillRegistry.Entry do
  @moduledoc """
  One skill fetched from a source (#2060): a SKILL.md (or, for a repository
  with none, its README). `name` and `description` come from its front
  matter, `body` is the whole file as fetched, `content_hash` its sha256
  (what a board pins), `version` the commit sha or the response's ETag,
  `licence` the repository's SPDX id. `path` is where it sits in the source,
  and is what a refresh matches entries on.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "skill_entries" do
    field :path, :string
    field :name, :string
    field :description, :string
    field :body, :string
    field :content_hash, :string
    field :version, :string
    field :licence, :string
    field :fetched_at, :utc_datetime
    belongs_to :source, Slipdock.SkillRegistry.Source
    timestamps(type: :utc_datetime)
  end

  @fields [:path, :name, :description, :body, :content_hash, :version, :licence, :fetched_at]

  def changeset(entry, attrs) do
    entry
    |> cast(attrs, @fields)
    |> validate_required([:path, :name, :body, :content_hash, :fetched_at])
    |> unique_constraint([:source_id, :path])
  end
end
