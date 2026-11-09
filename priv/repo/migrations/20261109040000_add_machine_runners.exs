defmodule Slipdock.Repo.Migrations.AddMachineRunners do
  @moduledoc """
  A runner belongs to a machine and is configured as typed data (#2571,
  epic #2569, W-2541).

  - `runners.machine_id`: the machine whose daemon runs it (nil for a
    shell runner or a Claude session). `config` is its closed, typed
    configuration and `config_version` goes up with each change. What the
    daemon last said about it: `accepted_version` and `accepted_config`
    (what it runs now), and `rejected_version`, `rejection` and
    `rejected_at` (the newest version it refused, and why).
  - `machines.ceiling` (with `ceiling_at`): the limits the machine reported
    from its own local file, kept to be shown; the server never sets it.
    `machines.config_version` goes up whenever any of its runners changes,
    which is what the daemon's long-poll waits on.
  - `machine_config_reports`: every accepted and rejected change, the log
    the Machines page shows.
  """
  use Ecto.Migration

  def change do
    alter table(:runners) do
      add :machine_id, references(:machines, on_delete: :delete_all)
      add :config, :map
      add :config_version, :integer, null: false, default: 0
      add :accepted_version, :integer
      add :accepted_config, :map
      add :rejected_version, :integer
      add :rejection, :text
      add :rejected_at, :utc_datetime
    end

    create index(:runners, [:machine_id])

    alter table(:machines) do
      add :ceiling, :map
      add :ceiling_at, :utc_datetime
      add :config_version, :integer, null: false, default: 0
    end

    create table(:machine_config_reports) do
      add :machine_id, references(:machines, on_delete: :delete_all), null: false
      add :runner_id, references(:runners, on_delete: :nilify_all)
      add :runner_name, :string
      add :version, :integer, null: false
      add :outcome, :string, null: false
      add :reason, :text
      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:machine_config_reports, [:machine_id, :id])
  end
end
