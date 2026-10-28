defmodule Slipdock.Repo.Migrations.CreateSavedMultiboards do
  use Ecto.Migration

  # Saved multiboards (#1482): a named Multiboard view, listed on its
  # owner's home page among their boards and vaults, in their own order.
  def change do
    create table(:saved_multiboards) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :color, :string, null: false, default: "indigo"
      add :position, :integer
      add :lists, {:array, :integer}, null: false, default: []
      add :top, :integer, null: false, default: 5
      add :by, :string, null: false, default: "board"

      timestamps(type: :utc_datetime)
    end

    create index(:saved_multiboards, [:user_id])
  end
end
