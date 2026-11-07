defmodule Slipdock.Repo.Migrations.AddCardIncidents do
  @moduledoc """
  Incidents (#1946): a card can name the card whose shipping caused it
  (`caused_by_id`, nilified when that card is deleted) and the check that
  should have caught it (`missed_by`: bar, rules, ci, verify, audit or none).
  """
  use Ecto.Migration

  def change do
    alter table(:cards) do
      add :caused_by_id, references(:cards, on_delete: :nilify_all)
      add :missed_by, :string
    end

    create index(:cards, [:caused_by_id])
  end
end
