defmodule Slipdock.Repo.Migrations.CreateSkillRegistry do
  @moduledoc """
  The external skills registry (#2060, spec W-2513): a source is a URL a user
  added (a GitHub repository, a path in one, or a single SKILL.md), and each
  SKILL.md fetched from it is an entry. A source with no owner is a seed,
  visible to everyone. Removing a source removes its entries.
  """
  use Ecto.Migration

  def change do
    create table(:skill_sources) do
      add :owner_id, references(:users, on_delete: :delete_all)
      add :url, :string, null: false, size: 2000
      add :kind, :string, null: false
      add :name, :string, null: false
      add :licence, :string
      add :version, :string
      add :fetched_at, :utc_datetime, null: false
      add :report, {:array, :string}, null: false, default: []
      timestamps(type: :utc_datetime)
    end

    create unique_index(:skill_sources, ["coalesce(owner_id, 0)", :url],
             name: :skill_sources_one_per_owner
           )

    create table(:skill_entries) do
      add :source_id, references(:skill_sources, on_delete: :delete_all), null: false
      add :path, :string, null: false, size: 1000
      add :name, :string, null: false
      add :description, :text
      add :body, :text, null: false
      add :content_hash, :string, null: false
      add :version, :string
      add :licence, :string
      add :fetched_at, :utc_datetime, null: false
      timestamps(type: :utc_datetime)
    end

    create unique_index(:skill_entries, [:source_id, :path])
    create index(:skill_entries, [:name])
  end
end
