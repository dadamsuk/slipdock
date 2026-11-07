defmodule Slipdock.Repo.Migrations.AddProfiles do
  use Ecto.Migration

  # Profiles (#1951): whether a board infers a card's profile when an agent
  # claims or starts it, and the card's profile (one of
  # `Slipdock.Profiles.names/0`, or none).
  def change do
    alter table(:boards) do
      add :profiles, :boolean, default: false, null: false
    end

    alter table(:cards) do
      add :profile, :string
    end
  end
end
