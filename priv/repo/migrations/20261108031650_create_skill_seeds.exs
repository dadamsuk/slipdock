defmodule Slipdock.Repo.Migrations.CreateSkillSeeds do
  @moduledoc """
  The skills registry's seeds (#2075, spec W-2513 §Seeds): each URL the
  server has seeded once, so a seed an admin removes isn't put back at the
  next boot. A seed whose fetch failed has no row, so the next boot tries it
  again.
  """
  use Ecto.Migration

  def change do
    create table(:skill_seeds) do
      add :url, :string, null: false, size: 2000
      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:skill_seeds, [:url])
  end
end
