defmodule Slipdock.Repo.Migrations.AddReleaseRequests do
  @moduledoc """
  Batched releases (#2835, epic #2833): a release request per root board,
  at most one running and one queued (the two partial unique indexes), and
  the board's release command (nil is the default,
  `Slipdock.Releases.default_command/0`).
  """
  use Ecto.Migration

  def change do
    alter table(:boards) do
      add :release_command, :string, size: 500
    end

    create table(:release_requests) do
      add :board_id, references(:boards, on_delete: :delete_all), null: false
      add :status, :string, null: false, default: "queued"
      # Every trigger that asked for it, oldest first: `trigger`, `by`, `at`.
      add :triggers, {:array, :map}, null: false, default: []
      # The merged, unreleased cards it covers, taken when it starts.
      add :card_ids, {:array, :integer}, null: false, default: []
      add :job_id, references(:runner_jobs, on_delete: :nilify_all)
      add :run_url, :string, size: 500
      add :note, :string, size: 500
      add :started_at, :utc_datetime_usec
      add :finished_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create index(:release_requests, [:board_id, :id])

    create unique_index(:release_requests, [:board_id],
             where: "status = 'running'",
             name: :release_requests_one_running
           )

    create unique_index(:release_requests, [:board_id],
             where: "status = 'queued'",
             name: :release_requests_one_queued
           )
  end
end
