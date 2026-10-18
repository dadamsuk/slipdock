defmodule Slipdock.Repo.Migrations.CreateGarden do
  use Ecto.Migration

  # The board gardener (#1079, W-1807): a run looks the board over, and each
  # thing it finds is a suggestion a person applies or dismisses. A decided
  # suggestion is kept, and its fingerprint is what stops it coming back.
  def change do
    create table(:garden_runs) do
      add :board_id, references(:boards, on_delete: :delete_all), null: false
      add :user_id, references(:users, on_delete: :nilify_all)
      add :trigger, :string, null: false
      add :started_at, :utc_datetime, null: false
      add :finished_at, :utc_datetime
      add :counts, :map, null: false, default: %{}

      timestamps(type: :utc_datetime)
    end

    create index(:garden_runs, [:board_id, :started_at])

    create table(:garden_suggestions) do
      add :run_id, references(:garden_runs, on_delete: :nilify_all)
      add :board_id, references(:boards, on_delete: :delete_all), null: false
      add :check, :string, null: false
      add :subject, :map, null: false, default: %{}
      add :fingerprint, :string, null: false
      add :proposal, {:array, :map}, null: false, default: []
      add :alternatives, :map, null: false, default: %{}
      add :explanation, :text, null: false
      add :state, :string, null: false, default: "open"
      add :decided_by_id, references(:users, on_delete: :nilify_all)
      add :decided_at, :utc_datetime
      # What applying it did, the other way round, for undo: the inverse
      # steps and the state each subject was left in.
      add :undo, :map

      timestamps(type: :utc_datetime)
    end

    create index(:garden_suggestions, [:board_id, :state])
    create index(:garden_suggestions, [:board_id, :fingerprint])
    create index(:garden_suggestions, [:run_id])
    create index(:garden_suggestions, [:decided_by_id])

    # Per-check switches and thresholds (board settings → Gardening).
    alter table(:boards) do
      add :gardening, :map, null: false, default: %{}
    end
  end
end
