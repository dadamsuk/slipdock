defmodule Slipdock.Repo.Migrations.AddOverseerHousekeepingDigest do
  @moduledoc """
  The morning digest of Housekeeping's work (#2781, epic #2776): the time
  of day the overseer writes it (`digest_at`, "HH:MM" in the owner's zone,
  07:00 unless set), and when it last did, so it is written once a day and
  covers what ran since.
  """
  use Ecto.Migration

  def change do
    alter table(:overseer_settings) do
      add :digest_at, :string, default: "07:00", null: false
      add :housekeeping_digest_on, :date
      add :housekeeping_digest_at, :utc_datetime
    end
  end
end
