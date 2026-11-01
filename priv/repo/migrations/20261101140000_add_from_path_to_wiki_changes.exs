defmodule Slipdock.Repo.Migrations.AddFromPathToWikiChanges do
  use Ecto.Migration

  def change do
    alter table(:wiki_changes) do
      add :from_path, :text
    end
  end
end
