defmodule Slipdock.Repo.Migrations.AddNotShippedWatch do
  use Ecto.Migration

  # The not-shipped watch (#2819): how long a merged card may go without a
  # deploy before the board is told, and since when the board has recorded
  # deploys. A board with delivery metrics already on starts counting from
  # now, so nothing merged before this shipped fires.
  def up do
    alter table(:boards) do
      add :not_shipped_minutes, :integer, null: false, default: 20
      add :delivery_metrics_since, :utc_datetime
    end

    execute "UPDATE boards SET delivery_metrics_since = now() WHERE delivery_metrics"
  end

  def down do
    alter table(:boards) do
      remove :not_shipped_minutes
      remove :delivery_metrics_since
    end
  end
end
