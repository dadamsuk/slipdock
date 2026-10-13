defmodule Slipdock.Repo.Migrations.AddPageCardFeaturesToBoards do
  use Ecto.Migration

  # Whether the pages of this board's wiki show the card contents under their
  # prose (status, checklist, links, fields, votes and comments). On for
  # every existing wiki; a wiki that is only documents can turn it off.
  def change do
    alter table(:boards) do
      add :page_card_features, :boolean, null: false, default: true
    end
  end
end
