defmodule Slipdock.Repo.Migrations.CreateKanban do
  use Ecto.Migration

  def change do
    create table(:boards) do
      add :name, :string, null: false
      add :description, :text
      add :color, :string, null: false, default: "indigo"
      timestamps(type: :utc_datetime)
    end

    create table(:columns) do
      add :board_id, references(:boards, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :position, :integer, null: false, default: 0
      add :wip_limit, :integer
      add :color, :string
      timestamps(type: :utc_datetime)
    end

    create index(:columns, [:board_id, :position])

    create table(:tags) do
      add :board_id, references(:boards, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :color, :string, null: false, default: "slate"
      timestamps(type: :utc_datetime)
    end

    create unique_index(:tags, [:board_id, :name])

    create table(:cards) do
      add :board_id, references(:boards, on_delete: :delete_all), null: false
      add :column_id, references(:columns, on_delete: :delete_all), null: false
      add :title, :string, null: false
      add :description, :text
      add :position, :integer, null: false, default: 0
      add :priority, :string, null: false, default: "none"
      add :flags, {:array, :string}, null: false, default: []
      add :due_date, :date
      add :completed, :boolean, null: false, default: false
      add :color, :string
      add :archived_at, :utc_datetime
      timestamps(type: :utc_datetime)
    end

    create index(:cards, [:column_id, :position])
    create index(:cards, [:board_id])

    create table(:card_tags, primary_key: false) do
      add :card_id, references(:cards, on_delete: :delete_all), null: false
      add :tag_id, references(:tags, on_delete: :delete_all), null: false
    end

    create unique_index(:card_tags, [:card_id, :tag_id])

    create table(:checklist_items) do
      add :card_id, references(:cards, on_delete: :delete_all), null: false
      add :text, :string, null: false
      add :done, :boolean, null: false, default: false
      add :position, :integer, null: false, default: 0
      timestamps(type: :utc_datetime)
    end

    create index(:checklist_items, [:card_id, :position])

    create table(:comments) do
      add :card_id, references(:cards, on_delete: :delete_all), null: false
      add :body, :text, null: false
      timestamps(type: :utc_datetime)
    end

    create index(:comments, [:card_id])

    create table(:activities) do
      add :board_id, references(:boards, on_delete: :delete_all), null: false
      add :card_id, references(:cards, on_delete: :nilify_all)
      add :kind, :string, null: false
      add :message, :string, null: false
      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:activities, [:board_id, :inserted_at])
  end
end
