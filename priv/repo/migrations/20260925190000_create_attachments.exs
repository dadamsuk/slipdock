defmodule Slipdock.Repo.Migrations.CreateAttachments do
  use Ecto.Migration

  def change do
    create table(:attachments) do
      add :card_id, references(:cards, on_delete: :delete_all), null: false
      add :filename, :string, null: false
      add :content_type, :string, null: false
      add :size, :integer, null: false
      # Where the bytes live, relative to the uploads directory.
      add :key, :string, null: false
      timestamps(type: :utc_datetime)
    end

    create index(:attachments, [:card_id])
    create unique_index(:attachments, [:key])
  end
end
