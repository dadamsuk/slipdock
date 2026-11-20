defmodule Slipdock.Runners.ConfigReport do
  @moduledoc """
  A line in a machine's log of changes, the one the Machines page shows.
  Mostly what its daemon said about one version of a runner's config
  (#2571): `accepted`, or `rejected` with the reason, written by
  `Slipdock.Runners.MachineRunners.report/3`. Or a board its owner added
  or removed (#3249): `board_added` or `board_removed`, with no runner, the
  machine's config version it went out in, and the board as the `reason`,
  written by `MachineRunners.set_boards/3`. Or a worktree the daemon pruned
  (#3489): `worktree_pruned`, its runner's, with what it did as the
  `reason`.
  """
  use Ecto.Schema

  schema "machine_config_reports" do
    field :runner_name, :string
    field :version, :integer
    field :outcome, :string
    field :reason, :string

    belongs_to :machine, Slipdock.Machines.Machine
    belongs_to :runner, Slipdock.Runners.Runner

    timestamps(type: :utc_datetime, updated_at: false)
  end
end
