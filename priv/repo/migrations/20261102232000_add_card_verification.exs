defmodule Slipdock.Repo.Migrations.AddCardVerification do
  use Ecto.Migration

  # Verified work 3 (#1633): a board can have an agent's completion wait for
  # a different agent (or a person) to accept it, or reject it with a reason.
  def change do
    alter table(:boards) do
      add :verify_work, :boolean, default: false, null: false
    end

    alter table(:cards) do
      add :verify_state, :string
      add :verify_note, :text
      add :verify_commit, :string
      add :verify_submitter, :map
      add :verify_by, :map
      add :verify_at, :utc_datetime
    end
  end
end
