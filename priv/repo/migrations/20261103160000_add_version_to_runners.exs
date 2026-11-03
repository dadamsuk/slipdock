defmodule Slipdock.Repo.Migrations.AddVersionToRunners do
  use Ecto.Migration

  # Ship by PR 5 (#1658): the runner script a runner said it is running
  # ("sh <sha256>" or "ps1 <sha256>"), nil until it says.
  def change do
    alter table(:runners) do
      add :version, :string
    end
  end
end
