defmodule Slipdock.Runners.ConfigReport do
  @moduledoc """
  What a machine's daemon said about one version of a runner's config
  (#2571): `accepted`, or `rejected` with the reason. The log of changes
  the Machines page shows; written only by
  `Slipdock.Runners.MachineRunners.report/3`.
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
