defmodule Slipdock.Repo.Migrations.AddDefaultViewToBoards do
  use Ecto.Migration

  # The view a board opens on (its wiki, its table…). nil, the board itself,
  # for every existing board.
  def change do
    alter table(:boards) do
      add :default_view, :string
    end
  end
end
