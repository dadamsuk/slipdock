defmodule Slipdock.Repo.Migrations.AddDeploymentStageAndRunUrl do
  use Ecto.Migration

  # A failed deploy attempt says where it failed and links its CI run (#2820).
  def change do
    alter table(:deployments) do
      add :stage, :string
      add :run_url, :text
    end
  end
end
