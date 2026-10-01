defmodule Slipdock.Repo.Migrations.AddPercentCompleteToCards do
  use Ecto.Migration

  def change do
    alter table(:cards) do
      add :percent_complete, :integer
    end
  end
end
