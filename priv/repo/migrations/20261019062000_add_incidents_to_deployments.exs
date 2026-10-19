defmodule Slipdock.Repo.Migrations.AddIncidentsToDeployments do
  use Ecto.Migration

  # Incidents (#1134): the tag that marks a board's incident cards (nil is
  # "incident"), how soon after a deploy a fix makes it a failed change, and
  # the deploy an incident card says caused it.
  def change do
    alter table(:boards) do
      add :incident_tag, :string
      add :hotfix_window_hours, :integer, null: false, default: 24
    end

    alter table(:cards) do
      add :caused_by_deployment_id, references(:deployments, on_delete: :nilify_all)
    end

    create index(:cards, [:caused_by_deployment_id])
  end
end
