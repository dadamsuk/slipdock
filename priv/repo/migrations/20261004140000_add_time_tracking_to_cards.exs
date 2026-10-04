defmodule Slipdock.Repo.Migrations.AddTimeTrackingToCards do
  use Ecto.Migration

  # Time spent and the estimate are whole minutes; `time_unit` is only how the
  # card shows them and how a bare number typed into them is read. A running
  # timer is the moment it started, and stopping it adds the difference.
  def change do
    alter table(:cards) do
      add :time_spent, :integer
      add :time_estimate, :integer
      add :time_unit, :string, null: false, default: "hours"
      add :timer_started_at, :utc_datetime
    end
  end
end
