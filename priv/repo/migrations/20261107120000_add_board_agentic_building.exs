defmodule Slipdock.Repo.Migrations.AddBoardAgenticBuilding do
  @moduledoc """
  Agentic Building (#2011): one switch that puts the board's agent settings
  on a page of their own. It changes no setting, so every board where one of
  them is already set turns it on (`Slipdock.AgenticBuilding.backfill_sql/0`)
  and nobody's settings disappear from sight on deploy.
  """
  use Ecto.Migration

  def up do
    alter table(:boards) do
      add :agentic_building, :boolean, default: false, null: false
    end

    flush()
    execute Slipdock.AgenticBuilding.backfill_sql()
  end

  def down do
    alter table(:boards) do
      remove :agentic_building
    end
  end
end
