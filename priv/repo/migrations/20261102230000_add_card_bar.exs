defmodule Slipdock.Repo.Migrations.AddCardBar do
  use Ecto.Migration

  # Verified work 1 (#1631): a board can ask for each card's bar (what done
  # means) to be written before work starts; it locks when work starts.
  def change do
    alter table(:boards) do
      add :bar_required, :boolean, default: false, null: false
    end

    alter table(:cards) do
      add :bar, :text
      add :bar_locked_at, :utc_datetime
    end
  end
end
