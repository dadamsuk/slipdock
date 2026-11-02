defmodule Slipdock.Repo.Migrations.AddCardEvidence do
  use Ecto.Migration

  # Verified work 2 (#1632): a board can ask an agent completing a card for
  # what it checked, and the commit it checked at.
  def change do
    alter table(:boards) do
      add :evidence_required, :boolean, default: false, null: false
    end

    alter table(:cards) do
      add :evidence, :text
      add :evidence_commit, :string
    end
  end
end
