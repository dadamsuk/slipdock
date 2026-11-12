defmodule Slipdock.Repo.Migrations.AddBoardReleaseMode do
  @moduledoc """
  Batched releases (#2834, epic #2833): how a board's merged work reaches
  production. `release_mode` is `on_merge` (every merge deploys, as before)
  or `batched` (merges wait for a release); `release_age_cap_hours` is how
  long a merge may wait before it triggers one (nil is off). Both are read
  from the tree's root board (`Slipdock.Releases`).
  """
  use Ecto.Migration

  def change do
    alter table(:boards) do
      add :release_mode, :string, null: false, default: "on_merge"
      add :release_age_cap_hours, :integer
    end
  end
end
