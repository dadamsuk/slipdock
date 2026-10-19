defmodule Slipdock.Repo.Migrations.AddRequeueJobToCardWaits do
  use Ecto.Migration

  # Re-queue on answer (#1115, KTD7): the fresh job an answered wait started,
  # so a claim can say which question it carries on from, and the answers
  # still waiting for their rule's open job to close.
  def change do
    alter table(:card_waits) do
      add :requeue_job_id, references(:runner_jobs, on_delete: :nilify_all)
    end

    create index(:card_waits, [:requeue_job_id])

    create index(:card_waits, [:job_id],
             where: "requeue_state = 'pending'",
             name: :card_waits_pending
           )
  end
end
