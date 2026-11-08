defmodule Slipdock.Repo.Migrations.CreateWaitingDismissalsAndMutes do
  @moduledoc """
  Waiting on you, trimmed by its person (#2069). A dismissal takes one item
  off one person's list, keyed on the card and the cause (`cause` is the
  failed job, the wait, the flag's run, ...), so a new cause on the card
  shows again. A mute keeps a board's tree off one person's list. Neither
  changes anything for anyone else.
  """
  use Ecto.Migration

  def change do
    create table(:waiting_dismissals) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :card_id, references(:cards, on_delete: :delete_all), null: false
      add :reason, :string, null: false
      add :cause, :string, null: false
      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:waiting_dismissals, [:user_id, :card_id, :cause])
    create index(:waiting_dismissals, [:card_id])

    create table(:waiting_mutes) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :board_id, references(:boards, on_delete: :delete_all), null: false
      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:waiting_mutes, [:user_id, :board_id])
    create index(:waiting_mutes, [:board_id])
  end
end
