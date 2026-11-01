defmodule Slipdock.Repo.Migrations.AddTreeNamesToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :tree_names, :string, null: false, default: "full"
    end
  end
end
