defmodule Slipdock.Repo.Migrations.AddShowPulseToBoards do
  use Ecto.Migration

  # Whether the board page shows its pulse as a strip (#1113). Off for
  # every board until its owner turns it on.
  def change do
    alter table(:boards) do
      add :show_pulse, :boolean, null: false, default: false
    end
  end
end
