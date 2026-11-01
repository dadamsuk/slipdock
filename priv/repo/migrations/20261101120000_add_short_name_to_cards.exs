defmodule Slipdock.Repo.Migrations.AddShortNameToCards do
  use Ecto.Migration

  def change do
    alter table(:cards) do
      add :short_name, :string, size: 40
      add :short_name_edited, :boolean, null: false, default: false
    end
  end
end
