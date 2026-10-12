defmodule Slipdock.Repo.Migrations.IndexWikiChangesInsertedAt do
  use Ecto.Migration

  # Old change-log rows are pruned by age (see `Slipdock.Wiki.Changes.prune/1`),
  # and the highest cursor pruned so far is kept, so a client asking from
  # below it is told to resync rather than silently missing what went.
  def change do
    create index(:wiki_changes, [:inserted_at])

    create table(:wiki_change_marks, primary_key: false) do
      add :name, :string, primary_key: true
      add :cursor, :bigint, null: false, default: 0
    end
  end
end
