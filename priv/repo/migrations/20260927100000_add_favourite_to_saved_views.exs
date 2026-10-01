defmodule Slipdock.Repo.Migrations.AddFavouriteToSavedViews do
  use Ecto.Migration

  def change do
    alter table(:saved_views) do
      # Favourite views are listed in the view switcher, next to the modes.
      add :favourite, :boolean, null: false, default: false
    end
  end
end
