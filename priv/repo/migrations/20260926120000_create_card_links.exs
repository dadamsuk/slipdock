defmodule Slipdock.Repo.Migrations.CreateCardLinks do
  use Ecto.Migration

  def change do
    # Typed links between cards, across boards: "relates to", "contributes
    # to" (a goal collects work from anywhere), "duplicates".
    create table(:card_links) do
      add :from_id, references(:cards, on_delete: :delete_all), null: false
      add :to_id, references(:cards, on_delete: :delete_all), null: false
      add :kind, :string, null: false
      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:card_links, [:from_id, :to_id, :kind])
    create index(:card_links, [:to_id])
  end
end
