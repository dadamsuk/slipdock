defmodule Slipdock.Repo.Migrations.CreateHealthMonitor do
  use Ecto.Migration

  def change do
    # What the health monitor found stuck (see `Slipdock.Health`), on the
    # root board of the tree it was found in.
    create table(:health_incidents) do
      add :board_id, references(:boards, on_delete: :delete_all), null: false
      add :card_id, references(:cards, on_delete: :nilify_all)
      add :detector, :string, null: false
      add :fingerprint, :string, null: false
      add :subject, :map, null: false, default: %{}
      add :summary, :text, null: false
      add :data, :map, null: false, default: %{}
      add :status, :string, null: false, default: "open"
      add :attempts, :integer, null: false, default: 0
      add :log, {:array, :map}, null: false, default: []
      add :alert_id, references(:alerts, on_delete: :nilify_all)
      add :flagged_at, :utc_datetime
      add :resolved_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:health_incidents, [:board_id, :status])
    create index(:health_incidents, [:card_id])
    create index(:health_incidents, [:board_id, :fingerprint])

    # The same state never has two incidents open at once.
    create unique_index(:health_incidents, [:board_id, :fingerprint],
             where: "status IN ('open', 'flagged')",
             name: :health_incidents_one_active
           )

    # A tree's detector switches and thresholds, only what it changed.
    create table(:health_settings) do
      add :board_id, references(:boards, on_delete: :delete_all), null: false
      add :settings, :map, null: false, default: %{}

      timestamps(type: :utc_datetime)
    end

    create unique_index(:health_settings, [:board_id])

    # When each clock last beat ("monitor", "scheduler"), so every node and
    # `/healthz` see the same thing.
    create table(:health_pulses, primary_key: false) do
      add :name, :string, primary_key: true
      add :at, :utc_datetime, null: false
    end
  end
end
