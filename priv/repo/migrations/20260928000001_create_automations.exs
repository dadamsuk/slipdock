defmodule Slipdock.Repo.Migrations.CreateAutomations do
  use Ecto.Migration

  def change do
    # A rule the user described in plain language, parsed into a spec of
    # {trigger, conditions, actions} that Slipdock.Automations.Runner executes.
    create table(:automation_rules) do
      add :board_id, references(:boards, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :source, :text
      add :spec, :map, null: false
      add :scope, :string, null: false, default: "board"
      add :enabled, :boolean, null: false, default: true
      add :run_count, :integer, null: false, default: 0
      add :last_run_at, :utc_datetime
      add :last_error, :string
      add :created_by_id, references(:users, on_delete: :nilify_all)
      timestamps(type: :utc_datetime)
    end

    create index(:automation_rules, [:board_id])

    # One row per thing a rule has already done, so the scheduled triggers
    # (stale, due soon, overdue, daily) fire once and not on every tick.
    create table(:automation_fires) do
      add :rule_id, references(:automation_rules, on_delete: :delete_all), null: false
      add :card_id, references(:cards, on_delete: :delete_all)
      add :key, :string, null: false
      add :inserted_at, :utc_datetime, null: false
    end

    create unique_index(:automation_fires, [:rule_id, :key])

    # Alerts raised by rules, shown in the header bar until dismissed.
    create table(:alerts) do
      add :board_id, references(:boards, on_delete: :delete_all), null: false
      add :card_id, references(:cards, on_delete: :delete_all)
      add :rule_id, references(:automation_rules, on_delete: :nilify_all)
      add :title, :string, null: false
      add :body, :text
      add :severity, :string, null: false, default: "info"
      timestamps(type: :utc_datetime)
    end

    create index(:alerts, [:board_id])
    create index(:alerts, [:card_id])

    # Dismissal is per person: one alert, dismissed by whoever has seen it.
    create table(:alert_dismissals) do
      add :alert_id, references(:alerts, on_delete: :delete_all), null: false
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :inserted_at, :utc_datetime, null: false
    end

    create unique_index(:alert_dismissals, [:alert_id, :user_id])
  end
end
