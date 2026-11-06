defmodule Slipdock.Repo.Migrations.AddDeploymentNote do
  use Ecto.Migration

  # A line CI writes about the deploy (#1857): how the suite was satisfied,
  # run again or passed already on the pull request at the same tree.
  def change do
    alter table(:deployments) do
      add :note, :string, size: 500
    end
  end
end
