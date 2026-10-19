defmodule Slipdock.Repo.Migrations.CreateCardWaits do
  use Ecto.Migration

  # Waiting on a person (#1114, KTD4): what is needed, from whom, since when,
  # and how it ended. A card has at most one open wait, which the partial
  # unique index holds to however two writers race.
  def change do
    create table(:card_waits) do
      add :card_id, references(:cards, on_delete: :delete_all), null: false
      add :needs, :text, null: false
      add :on_user_id, references(:users, on_delete: :nilify_all)
      add :choices, {:array, :string}, null: false, default: []
      add :opened_by_id, references(:users, on_delete: :nilify_all)
      add :kind, :string
      add :via, :string
      add :agent, :string
      add :job_id, references(:runner_jobs, on_delete: :nilify_all)
      add :set_flag, :boolean, null: false, default: false
      add :closed_at, :utc_datetime
      add :closed_by_id, references(:users, on_delete: :nilify_all)
      add :close_reason, :string
      add :answer, :text
      add :choice, :integer
      add :requeue_state, :string, null: false, default: "none"
      add :requeue_note, :text

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:card_waits, [:card_id],
             where: "closed_at IS NULL",
             name: :card_waits_one_open
           )

    create index(:card_waits, [:card_id, :inserted_at])
    create index(:card_waits, [:on_user_id], where: "closed_at IS NULL")
    create index(:card_waits, [:opened_by_id])
    create index(:card_waits, [:closed_by_id])
    create index(:card_waits, [:job_id])
  end
end
