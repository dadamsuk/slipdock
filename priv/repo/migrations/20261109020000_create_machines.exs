defmodule Slipdock.Repo.Migrations.CreateMachines do
  @moduledoc """
  Machines (#2570, epic #2569): a computer running the runner daemon, bound
  to the account that approved it, with a key of its own (only its hash is
  kept). `machine_enrolments` are the pending device-code requests that make
  one; `machine_enrolment_keys` the one-time keys that make one headlessly.
  A revoked machine keeps its row, so the record of what it was stays.
  """
  use Ecto.Migration

  def change do
    create table(:machines) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :hostname, :string, null: false
      add :os, :string
      add :arch, :string
      add :fingerprint, :string
      add :key_hash, :binary, null: false
      add :board_ids, {:array, :integer}, null: false, default: []
      add :enrolled_via, :string, null: false
      add :last_seen_at, :utc_datetime
      add :last_seen_ip, :string
      add :revoked_at, :utc_datetime
      timestamps(type: :utc_datetime)
    end

    create unique_index(:machines, [:key_hash])
    create index(:machines, [:user_id])

    create table(:machine_enrolments) do
      add :device_code, :binary, null: false
      add :user_code, :string, null: false
      add :hostname, :string, null: false
      add :os, :string
      add :arch, :string
      add :fingerprint, :string
      add :client_ip, :string
      add :board_ids, {:array, :integer}, null: false, default: []
      add :user_id, references(:users, on_delete: :delete_all)
      add :expires_at, :utc_datetime, null: false
      add :approved_at, :utc_datetime
      add :denied_at, :utc_datetime
      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:machine_enrolments, [:device_code])
    create index(:machine_enrolments, [:user_code])

    create table(:machine_enrolment_keys) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :key_hash, :binary, null: false
      add :label, :string
      add :board_ids, {:array, :integer}, null: false, default: []
      add :expires_at, :utc_datetime, null: false
      add :used_at, :utc_datetime
      add :machine_id, references(:machines, on_delete: :nilify_all)
      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:machine_enrolment_keys, [:key_hash])
    create index(:machine_enrolment_keys, [:user_id])
  end
end
