defmodule Slipdock.Repo.Migrations.CreateCardHandoffs do
  use Ecto.Migration

  # Where a card was left (#1043, W-1804): one row per write, the newest is
  # the card's handoff and the rest its history. A row with no next step is a
  # clear, kept so the history shows it was cleared.
  def change do
    create table(:card_handoffs) do
      add :card_id, references(:cards, on_delete: :delete_all), null: false
      add :user_id, references(:users, on_delete: :nilify_all)
      add :job_id, references(:runner_jobs, on_delete: :nilify_all)
      add :via, :string, null: false
      add :next_step, :text
      add :body, :text

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:card_handoffs, [:card_id, :inserted_at])
    create index(:card_handoffs, [:user_id])
    create index(:card_handoffs, [:job_id])
  end
end
