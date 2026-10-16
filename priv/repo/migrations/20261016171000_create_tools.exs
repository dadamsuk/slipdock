defmodule Slipdock.Repo.Migrations.CreateTools do
  use Ecto.Migration

  # Tools (#958, #960): packaged docs, files, a board blueprint and skills
  # that other people on this server can install. A version is immutable once
  # published and is identified by the sha over its files; the files
  # themselves are kept in `tool_files`, one row each.
  def change do
    create table(:tools) do
      add :slug, :string, null: false
      add :name, :string, null: false
      add :summary, :string
      add :owner_id, references(:users, on_delete: :delete_all), null: false
      timestamps(type: :utc_datetime)
    end

    create unique_index(:tools, [:slug])
    create index(:tools, [:owner_id])

    create table(:tool_versions) do
      add :tool_id, references(:tools, on_delete: :delete_all), null: false
      add :version, :string, null: false
      add :sha, :string, null: false
      add :manifest, :map, null: false, default: %{}
      add :readme, :text, null: false, default: ""
      add :board, :map
      add :size, :bigint, null: false, default: 0
      add :published_by_id, references(:users, on_delete: :nilify_all)
      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:tool_versions, [:tool_id, :version])
    create index(:tool_versions, [:sha])

    create table(:tool_files) do
      add :version_id, references(:tool_versions, on_delete: :delete_all), null: false
      add :path, :string, null: false
      add :content, :binary, null: false
      add :size, :integer, null: false
      add :sha256, :string, null: false
    end

    create unique_index(:tool_files, [:version_id, :path])
  end
end
