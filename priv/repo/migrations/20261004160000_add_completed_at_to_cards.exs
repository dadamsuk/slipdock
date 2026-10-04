defmodule Slipdock.Repo.Migrations.AddCompletedAtToCards do
  use Ecto.Migration

  # When a card was completed, so a sprint's burndown can say how much work
  # was left on each day. Cards already completed take the time of the last
  # "completed" line in their activity, else the last time they changed.
  def up do
    alter table(:cards) do
      add :completed_at, :utc_datetime
    end

    flush()

    execute("""
    UPDATE cards SET completed_at = COALESCE(
      (SELECT max(a.inserted_at) FROM activities a
        WHERE a.card_id = cards.id AND a.message LIKE 'completed “%'),
      cards.updated_at)
    WHERE cards.completed
    """)
  end

  def down do
    alter table(:cards) do
      remove :completed_at
    end
  end
end
