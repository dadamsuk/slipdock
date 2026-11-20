defmodule Slipdock.Repo.Migrations.AddCardsTextBy do
  use Ecto.Migration

  # Who wrote a card's title, description and bar (#3516): the ids of the
  # people who set them, 0 for someone with no account here. Nil on the
  # cards already there, which fall back to whoever created them.
  def change do
    alter table(:cards) do
      add :text_by, {:array, :bigint}
    end
  end
end
