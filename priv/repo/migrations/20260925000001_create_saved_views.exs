defmodule Slipdock.Repo.Migrations.CreateSavedViews do
  use Ecto.Migration

  def change do
    create table(:saved_views) do
      add :board_id, references(:boards, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :config, :map, null: false, default: %{}
      timestamps(type: :utc_datetime)
    end

    create unique_index(:saved_views, [:board_id, :name])
  end
end
