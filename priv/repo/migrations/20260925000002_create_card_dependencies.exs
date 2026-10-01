defmodule Slipdock.Repo.Migrations.CreateCardDependencies do
  use Ecto.Migration

  def change do
    create table(:card_dependencies, primary_key: false) do
      add :blocker_id, references(:cards, on_delete: :delete_all), null: false
      add :blocked_id, references(:cards, on_delete: :delete_all), null: false
    end

    create unique_index(:card_dependencies, [:blocked_id, :blocker_id])
    create index(:card_dependencies, [:blocker_id])
  end
end
