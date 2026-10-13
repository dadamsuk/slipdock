defmodule Slipdock.Repo.Migrations.CreateTreeStates do
  use Ecto.Migration

  # Which folders a reader has open in a wiki's tree, kept per reader and per
  # tree — a board's own, or a vault's (W-103 R11.7). A reader's convenience,
  # so it goes with them.
  def change do
    create table(:tree_states) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :scope, :string, null: false
      add :open, {:array, :string}, null: false, default: []

      timestamps(type: :utc_datetime)
    end

    create unique_index(:tree_states, [:user_id, :scope])
  end
end
