defmodule Slipdock.Repo.Migrations.AddBoardShipVia do
  use Ecto.Migration

  # Ship by PR 1 (#1654): how a board's verified work reaches the default
  # branch, "push" (as before) or "pull_request"; and the pull request an
  # agent's completion names in its evidence.
  def change do
    alter table(:boards) do
      add :ship_via, :string, default: "push", null: false
    end

    alter table(:cards) do
      add :evidence_pr, :string
    end
  end
end
