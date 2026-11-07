defmodule Slipdock.Repo.Migrations.AddJobCostColumns do
  @moduledoc """
  Cost on the card (#1954): what a job's log says it spent, kept on the job
  so it outlives the log. Model and tool seconds from the log's summary,
  and token usage summed from the lines that carry it (null when none
  did). `cost_lines` is how many lines of the log were counted, so the
  count is redone only when the log has grown.
  """
  use Ecto.Migration

  def change do
    alter table(:runner_jobs) do
      add :model_seconds, :integer
      add :tool_seconds, :integer
      add :tokens, :map
      add :cost_lines, :integer, default: 0, null: false
    end
  end
end
