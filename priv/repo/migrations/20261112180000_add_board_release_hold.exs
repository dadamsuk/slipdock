defmodule Slipdock.Repo.Migrations.AddBoardReleaseHold do
  @moduledoc """
  A red release holds releases (#2838, epic #2833; numbered after
  #2819's 20261112120000): `release_hold` on a
  tree's root board is nil while releases run, and once a release's suite or
  deploy fails, a map of why (`reason`, `stage`, `run_url`, `sha`,
  `deployment_id`, `card_ids`, `fix_card_id`, `held_at`), kept by
  `Slipdock.Releases` until the fix card merges or a person lifts it.
  Additive: an older image ignores the column.
  """
  use Ecto.Migration

  def change do
    alter table(:boards) do
      add :release_hold, :map
    end
  end
end
