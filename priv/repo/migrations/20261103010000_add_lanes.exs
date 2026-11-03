defmodule Slipdock.Repo.Migrations.AddLanes do
  use Ecto.Migration

  # Lanes 2 (#1628): a card can declare the paths it will touch, and a board
  # can refuse an agent starting a card whose paths overlap one in progress.
  def change do
    alter table(:boards) do
      add :lanes, :boolean, default: false, null: false
    end

    alter table(:cards) do
      add :paths, {:array, :string}, default: [], null: false
    end
  end
end
