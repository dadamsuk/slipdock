defmodule Slipdock.Repo.Migrations.AddCardProfileSource do
  @moduledoc """
  Where a card's profile came from (#2018): "inferred", or set by a
  "person", an "agent" or a "rule"; nil when it has none or nobody recorded
  it. A profile already on a card whose activity has the line
  "profile inferred: <that profile>" was inferred, and says so; the rest are
  left unrecorded rather than guessed.
  """
  use Ecto.Migration

  def up do
    alter table(:cards) do
      add :profile_source, :string
    end

    flush()

    execute """
    UPDATE cards SET profile_source = 'inferred'
    WHERE cards.profile IS NOT NULL
      AND EXISTS (
        SELECT 1 FROM activities a
        WHERE a.card_id = cards.id
          AND a.message = 'profile inferred: ' || cards.profile
      )
    """
  end

  def down do
    alter table(:cards) do
      remove :profile_source
    end
  end
end
