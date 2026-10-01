defmodule Slipdock.Repo.Migrations.CreateCardUrls do
  use Ecto.Migration

  def change do
    create table(:card_urls) do
      add :url, :string, null: false
      add :title, :string
      add :card_id, references(:cards, on_delete: :delete_all), null: false
      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:card_urls, [:card_id])
  end
end
