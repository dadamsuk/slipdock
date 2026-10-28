defmodule Slipdock.Repo.Migrations.AddMultiboardToUsers do
  use Ecto.Migration

  # The multiboard overview (#1479): which lists it shows, how many cards
  # of each and how they are laid out, remembered between visits.
  def change do
    alter table(:users) do
      add :multiboard, :map, null: false, default: %{}
    end
  end
end
