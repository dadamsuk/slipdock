defmodule Slipdock.Repo.Migrations.AddCardOrigin do
  @moduledoc """
  Origin on cards (#2778, epic #2776): who or what made each card from now
  on (`Slipdock.Origin`), and the runner job when an agent made it during
  one. Cards made before this have none; nothing is backfilled.
  """
  use Ecto.Migration

  def change do
    alter table(:cards) do
      add :origin, :string
      # Not a foreign key: a job's history may be pruned, the record stays.
      add :origin_job_id, :bigint
    end

    create index(:cards, [:board_id, :origin])
  end
end
