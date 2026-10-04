defmodule Slipdock.Repo.Migrations.AddStandInForToCards do
  use Ecto.Migration

  # A stand-in: the card sprint planning leaves where a card it pulled in used
  # to be, pointing at the card (see `Slipdock.Sprints.add_cards/2`). No
  # foreign key on purpose — when the real card is deleted the stand-in has
  # to stay a stand-in, saying so, rather than be cascaded away or nilified
  # into an ordinary card.
  def change do
    alter table(:cards) do
      add :stand_in_for_id, :bigint
    end

    create index(:cards, [:stand_in_for_id])
  end
end
