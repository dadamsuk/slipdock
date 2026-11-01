defmodule Slipdock.Repo.Migrations.AddCardIdToPageFolders do
  use Ecto.Migration

  def change do
    alter table(:page_folders) do
      add :card_id, references(:cards, on_delete: :nilify_all)
    end

    create unique_index(:page_folders, [:card_id], where: "card_id IS NOT NULL")
  end
end
