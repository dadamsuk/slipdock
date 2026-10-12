defmodule Slipdock.Repo.Migrations.AddHideOnCardToAttachments do
  use Ecto.Migration

  # An image attached to a card shows as a thumbnail on the card's front
  # unless somebody ticks "Don't show on the card front" beside it.
  def change do
    alter table(:attachments) do
      add :hide_on_card, :boolean, default: false, null: false
    end
  end
end
