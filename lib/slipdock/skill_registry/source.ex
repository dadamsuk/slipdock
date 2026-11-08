defmodule Slipdock.SkillRegistry.Source do
  @moduledoc """
  A skill source (#2060): a URL a user added, from which the server fetched
  one or more entries. `kind` is `github` (a repository, or a path in one) or
  `file` (one SKILL.md at any https URL). `owner_id` is nil for a seed, which
  every user sees. `report` holds what the last fetch skipped and why, as
  sentences. Never cast from a request beyond the URL: the fetch fills the rest.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @kinds ~w(github file)

  schema "skill_sources" do
    field :url, :string
    field :kind, :string
    field :name, :string
    field :licence, :string
    field :version, :string
    field :fetched_at, :utc_datetime
    field :report, {:array, :string}, default: []
    belongs_to :owner, Slipdock.Accounts.User
    has_many :entries, Slipdock.SkillRegistry.Entry, preload_order: [asc: :name]
    timestamps(type: :utc_datetime)
  end

  @doc "The fields a fetch sets."
  def changeset(source, attrs) do
    source
    |> cast(attrs, [:url, :kind, :name, :licence, :version, :fetched_at, :report])
    |> validate_required([:url, :kind, :name, :fetched_at])
    |> validate_inclusion(:kind, @kinds)
    |> validate_length(:url, max: 2000)
    |> unique_constraint(:url,
      name: :skill_sources_one_per_owner,
      message: "is already one of your sources"
    )
  end
end
