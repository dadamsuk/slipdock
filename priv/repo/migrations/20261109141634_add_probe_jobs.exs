defmodule Slipdock.Repo.Migrations.AddProbeJobs do
  @moduledoc """
  The probe (#2580, epic #2569, W-2544 §8): a job of kind `probe`, sent by
  a machine's owner to one of its runners, with no card.

  - `runner_jobs.card_id` may be null: a probe is about a runner, not a
    card. Every other job still has one.
  - `runner_jobs.for_runner_id`: the one runner that may take the job. A
    probe goes to the runner it was sent to, never to another in its pool,
    and goes with that runner if it is removed.
  """
  use Ecto.Migration

  def up do
    execute "ALTER TABLE runner_jobs ALTER COLUMN card_id DROP NOT NULL"

    alter table(:runner_jobs) do
      add :for_runner_id, references(:runners, on_delete: :delete_all)
    end

    create index(:runner_jobs, [:for_runner_id, :status], where: "for_runner_id IS NOT NULL")
  end

  def down do
    execute "DELETE FROM runner_jobs WHERE card_id IS NULL"
    drop index(:runner_jobs, [:for_runner_id, :status])

    alter table(:runner_jobs) do
      remove :for_runner_id
    end

    execute "ALTER TABLE runner_jobs ALTER COLUMN card_id SET NOT NULL"
  end
end
