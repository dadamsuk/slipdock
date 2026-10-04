defmodule Slipdock.Repo.Migrations.CreateCardAssignees do
  use Ecto.Migration

  # A card can be assigned to several people. `cards.assignee_id` stays, as
  # the lead — the first of them — so everything that colours or sorts by one
  # person keeps working; this table is the whole set.
  def up do
    create table(:card_assignees, primary_key: false) do
      add :card_id, references(:cards, on_delete: :delete_all), null: false
      add :user_id, references(:users, on_delete: :delete_all), null: false
    end

    create unique_index(:card_assignees, [:card_id, :user_id])
    create index(:card_assignees, [:user_id])

    execute """
    INSERT INTO card_assignees (card_id, user_id)
    SELECT id, assignee_id FROM cards WHERE assignee_id IS NOT NULL
    """
  end

  def down do
    drop table(:card_assignees)
  end
end
