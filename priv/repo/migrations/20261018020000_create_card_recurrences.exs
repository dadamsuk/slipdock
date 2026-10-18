defmodule Slipdock.Repo.Migrations.CreateCardRecurrences do
  use Ecto.Migration

  # Recurring cards (W-1802, #1051): one row per series. `card_id` is the
  # series' current instance and moves on to each new one; deleting it ends
  # the series. Every instance points back with `cards.series_id`, which
  # outlives the series as a plain marker.
  def change do
    create table(:card_recurrences) do
      add :card_id, references(:cards, on_delete: :delete_all), null: false
      add :kind, :string, null: false, default: "fixed"
      add :rule, :string, null: false
      add :starts_on, :date, null: false
      add :create_at, :time, null: false, default: "07:00:00"
      add :timezone, :string, null: false, default: "Etc/UTC"
      add :lead_days, :integer, null: false, default: 0
      add :column_id, references(:columns, on_delete: :nilify_all)
      add :on_missed, :string, null: false, default: "bump"
      add :ends, :string, null: false, default: "never"
      add :ends_on, :date
      add :count, :integer
      add :made, :integer, null: false, default: 1
      add :next_on, :date
      add :next_at, :utc_datetime
      add :paused, :boolean, null: false, default: false
      add :ended_at, :utc_datetime
      add :last_created_card_id, references(:cards, on_delete: :nilify_all)
      add :created_by_id, references(:users, on_delete: :nilify_all)
      timestamps(type: :utc_datetime)
    end

    create unique_index(:card_recurrences, [:card_id])
    create index(:card_recurrences, [:next_at], where: "NOT paused AND ended_at IS NULL")

    alter table(:cards) do
      add :series_id, references(:card_recurrences, on_delete: :nilify_all)
    end

    create index(:cards, [:series_id])

    # The occasion keys: one row per occurrence a series has acted on, so two
    # nodes ticking at once, or a restart mid-tick, never make two instances.
    create table(:recurrence_fires) do
      add :recurrence_id, references(:card_recurrences, on_delete: :delete_all), null: false
      add :key, :string, null: false
      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:recurrence_fires, [:recurrence_id, :key])
  end
end
