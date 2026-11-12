defmodule Slipdock.Repo.Migrations.AddJobLastRunner do
  @moduledoc """
  A job held across a machine's sleep (#2817): `runner_jobs.last_runner_id`
  is the runner that held a job when its lease ran out and the sweep put it
  back in the queue. While the job is still queued, that runner's next
  heartbeat takes it back; any claim clears it. It goes with the runner if
  that is removed.
  """
  use Ecto.Migration

  def change do
    alter table(:runner_jobs) do
      add :last_runner_id, references(:runners, on_delete: :nilify_all)
    end
  end
end
