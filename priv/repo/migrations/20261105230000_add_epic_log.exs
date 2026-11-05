defmodule Slipdock.Repo.Migrations.AddEpicLog do
  use Ecto.Migration

  # Epic comments (#1881): the server's own lines on an epic are marked so
  # the next can join them, and a % complete a person set by hand is kept.
  def change do
    alter table(:comments) do
      add :kind, :string
    end

    alter table(:cards) do
      add :percent_by_hand, :boolean, null: false, default: false
    end
  end
end
