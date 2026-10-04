defmodule Slipdock.Repo.Migrations.AddSprintSourcesToBoards do
  use Ecto.Migration

  # Where a sprint board's sprints are planned from: a list of
  # %{"board_id", "column_ids"}, the boards and the lists on them that the
  # planning view shows (see `Slipdock.Sprints.sources/2`). Empty until the
  # person chooses, when Add cards… falls back to browsing board by board.
  def change do
    alter table(:boards) do
      add :sprint_sources, :map
    end
  end
end
