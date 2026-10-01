defmodule Slipdock.Repo.Migrations.AddStartDateToCards do
  use Ecto.Migration

  def change do
    alter table(:cards) do
      add :start_date, :date
    end
  end
end
