defmodule Slipdock.Repo.Migrations.CreateOverseer do
  use Ecto.Migration

  # The overseer (#2068): one row of settings per root board, and the
  # conditions its watch checks have raised, open until they clear.
  def change do
    create table(:overseer_settings) do
      add :board_id, references(:boards, on_delete: :delete_all), null: false
      add :enabled, :boolean, null: false, default: false
      add :pool, :string, null: false, default: "default"
      add :min_minutes, :integer, null: false, default: 10
      add :max_minutes, :integer, null: false, default: 120
      add :idle_minutes, :integer, null: false, default: 15
      add :email, :boolean, null: false, default: true
      # The completed card on the root board the overseer's jobs hang off,
      # and whose status updates are its digests.
      add :card_id, references(:cards, on_delete: :nilify_all)
      add :next_run_at, :utc_datetime
      add :last_queued_at, :utc_datetime
      add :last_job_id, references(:runner_jobs, on_delete: :nilify_all)
      add :last_digest, :text
      add :last_health, :string
      add :last_digest_at, :utc_datetime
      add :watched_at, :utc_datetime
      timestamps(type: :utc_datetime)
    end

    create unique_index(:overseer_settings, [:board_id])
    create index(:overseer_settings, [:enabled])

    create table(:overseer_conditions) do
      add :board_id, references(:boards, on_delete: :delete_all), null: false
      add :check, :string, null: false
      add :subject, :string, null: false
      add :card_id, references(:cards, on_delete: :delete_all)
      add :severity, :string, null: false, default: "warning"
      add :title, :string, null: false
      add :why, :text, null: false
      add :todo, :text, null: false
      add :alert_id, references(:alerts, on_delete: :nilify_all)
      add :opened_at, :utc_datetime, null: false
      add :cleared_at, :utc_datetime
      timestamps(type: :utc_datetime)
    end

    # Once per condition: one open row per board, check and subject.
    create unique_index(:overseer_conditions, [:board_id, :check, :subject],
             where: "cleared_at IS NULL",
             name: :overseer_conditions_one_open
           )

    create index(:overseer_conditions, [:board_id, :cleared_at])
    create index(:overseer_conditions, [:card_id])
  end
end
