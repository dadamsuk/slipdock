defmodule Slipdock.Repo.Migrations.AddEditorsMayShareToBoards do
  use Ecto.Migration

  # Whether people who can edit a board may share its cards, pages and
  # folders with others (#3558). Off for every board until its owner turns
  # it on; read on the tree's top board.
  def change do
    alter table(:boards) do
      add :editors_may_share, :boolean, null: false, default: false
    end
  end
end
