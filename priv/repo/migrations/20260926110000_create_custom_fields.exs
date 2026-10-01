defmodule Slipdock.Repo.Migrations.CreateCustomFields do
  use Ecto.Migration

  def change do
    create table(:field_definitions) do
      # Fields belong to the root board and apply to every card in the tree.
      add :board_id, references(:boards, on_delete: :delete_all), null: false
      add :name, :string, null: false
      # A short identifier used in formulas as {key}.
      add :key, :string, null: false
      # number / rating / select / date / text / formula
      add :kind, :string, null: false
      add :position, :integer, null: false, default: 0
      # select: [%{key, label, weight, color}]
      add :options, :map, null: false, default: "[]"
      # number: min, max, step, unit; rating: max; formula: mode, expression, weights
      add :config, :map, null: false, default: "{}"
      # Roll the field's values up the tree (totals per card, done and all).
      add :sum, :boolean, null: false, default: false
      timestamps(type: :utc_datetime)
    end

    create unique_index(:field_definitions, [:board_id, :key])
    create index(:field_definitions, [:board_id, :position])

    create table(:card_field_values) do
      add :card_id, references(:cards, on_delete: :delete_all), null: false
      add :field_id, references(:field_definitions, on_delete: :delete_all), null: false
      add :number, :float
      add :text, :text
      add :date, :date
      add :option, :string
      timestamps(type: :utc_datetime)
    end

    create unique_index(:card_field_values, [:card_id, :field_id])
    create index(:card_field_values, [:field_id])

    create table(:votes) do
      add :card_id, references(:cards, on_delete: :delete_all), null: false
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :count, :integer, null: false, default: 1
      add :comment, :string
      timestamps(type: :utc_datetime)
    end

    create unique_index(:votes, [:card_id, :user_id])

    alter table(:boards) do
      # Budget voting: votes each person may spend across the tree, and the
      # most one card can take from one person.
      add :vote_budget, :integer, null: false, default: 10
      add :vote_max, :integer, null: false, default: 5
    end
  end
end
