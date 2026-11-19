defmodule Slipdock.Repo.Migrations.AddCloseOnCompleteToBoards do
  use Ecto.Migration

  # Whether completing an open card from its Complete icon closes it back
  # to the board (#3473). Off for every board until its owner turns it on.
  def change do
    alter table(:boards) do
      add :close_on_complete, :boolean, null: false, default: false
    end
  end
end
