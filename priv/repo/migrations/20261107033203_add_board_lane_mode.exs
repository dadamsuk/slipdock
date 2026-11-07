defmodule Slipdock.Repo.Migrations.AddBoardLaneMode do
  @moduledoc """
  Advisory lanes (#1972): a board's lane mode, `off`, `hold` (what `lanes`
  has meant: refuse an agent's overlapping start, hold its job) or `advise`
  (tell the agent in its job's prompt instead). `lanes` stays, true when the
  mode isn't `off`. A board with lanes on keeps them as `hold`.
  """
  use Ecto.Migration

  def up do
    alter table(:boards) do
      add :lane_mode, :string, default: "off", null: false
    end

    execute "UPDATE boards SET lane_mode = 'hold' WHERE lanes"
  end

  def down do
    alter table(:boards) do
      remove :lane_mode
    end
  end
end
