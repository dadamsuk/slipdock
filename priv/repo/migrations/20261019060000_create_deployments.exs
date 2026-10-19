defmodule Slipdock.Repo.Migrations.CreateDeployments do
  use Ecto.Migration

  # The deployments ledger (#1134, see `Slipdock.Deployments.Deployment`):
  # one row per deploy of a board's project to an environment, written by CI
  # and read only by queries. Commits ride on the row as JSON; `card_ids` is
  # every card they name, so "which deploys shipped this card" is one lookup.
  # And the board switch that lets deploys in at all, off for every board.
  def change do
    create table(:deployments) do
      add :board_id, references(:boards, on_delete: :delete_all), null: false
      add :environment, :string, null: false
      add :sha, :string, null: false
      add :tag, :string
      add :previous_sha, :string
      add :status, :string, null: false
      add :started_at, :utc_datetime_usec, null: false
      add :finished_at, :utc_datetime_usec
      add :source, :string, null: false, default: "api"
      add :commits, :map, null: false, default: fragment("'[]'::jsonb")
      add :card_ids, {:array, :bigint}, null: false, default: []
      add :rollback, :boolean, null: false, default: false

      timestamps(type: :utc_datetime_usec)
    end

    # The last succeeded deploy per board and environment, and time ranges.
    create index(:deployments, [:board_id, :environment, :status, :finished_at])
    create index(:deployments, [:board_id, :started_at])
    create index(:deployments, [:card_ids], using: :gin)

    alter table(:boards) do
      add :delivery_metrics, :boolean, null: false, default: false
    end
  end
end
