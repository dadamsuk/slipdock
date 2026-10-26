defmodule Slipdock.Repo.Migrations.AddShowAgeToColumns do
  use Ecto.Migration

  # Whether a list's cards show how long they have sat in it: on unless a
  # list's settings turn it off.
  def change do
    alter table(:columns) do
      add :show_age, :boolean, null: false, default: true
    end
  end
end
