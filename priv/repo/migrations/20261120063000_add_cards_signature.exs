defmodule Slipdock.Repo.Migrations.AddCardsSignature do
  use Ecto.Migration

  # The owner's passkey signature over a card's title, description and bar
  # (#3532, `Slipdock.Intent`): the assertion, when it was signed, and the
  # SHA-256 of the canonical text it signed, so an edit by any path reads
  # as unsigned. Nil on every card until its owner signs it.
  def change do
    alter table(:cards) do
      add :signature, :map
      add :signed_at, :utc_datetime
      add :signed_hash, :binary
    end
  end
end
