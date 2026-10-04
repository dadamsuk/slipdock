defmodule Slipdock.Repo.Migrations.AddSimpleToBoards do
  use Ecto.Migration

  # A simple board is a plain to-do list: the project-tracking details —
  # % complete, start dates, health, time, votes, dependencies, the timeline
  # and prioritise views — are put out of sight. Nothing is deleted.
  def change do
    alter table(:boards) do
      add :simple, :boolean, null: false, default: false
    end
  end
end
