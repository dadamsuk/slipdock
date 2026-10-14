defmodule Slipdock.Repo.Migrations.WikiIconsAndColours do
  use Ecto.Migration

  # A wiki folder or page can wear an icon and a colour (#792). A page
  # already has a colour (its cover, a card facet), so it only gains the
  # icon. Whether the tree shows them is the board's choice, on unless
  # turned off.
  def change do
    alter table(:page_folders) do
      add :icon, :string
      add :color, :string
    end

    alter table(:pages) do
      add :icon, :string
    end

    alter table(:boards) do
      add :wiki_tree_icons, :boolean, null: false, default: true
    end
  end
end
