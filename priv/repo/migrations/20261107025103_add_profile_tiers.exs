defmodule Slipdock.Repo.Migrations.AddProfileTiers do
  use Ecto.Migration

  # The human tier (#1952): a board's changes to each profile's default
  # tier (`Slipdock.Profiles.default_tiers/0`), only the ones that differ.
  def change do
    alter table(:boards) do
      add :profile_tiers, :map, default: %{}, null: false
    end
  end
end
