defmodule Slipdock.Health.Pulse do
  @moduledoc """
  When a clock last beat: `"monitor"` (the health monitor's last run) and
  `"scheduler"` (the scheduler's last tick). Kept in the database, so every
  node, and `/healthz`, see the same thing.
  """
  use Ecto.Schema

  alias Slipdock.Repo

  @primary_key {:name, :string, autogenerate: false}
  schema "health_pulses" do
    field :at, :utc_datetime
  end

  @doc "Records that `name` beat at `at`."
  def beat(name, at \\ DateTime.utc_now()) do
    at = DateTime.truncate(at, :second)

    Repo.insert!(%__MODULE__{name: name, at: at},
      on_conflict: [set: [at: at]],
      conflict_target: :name
    )

    :ok
  end

  @doc "When `name` last beat, or nil."
  def last(name) do
    case Repo.get(__MODULE__, name) do
      %__MODULE__{at: at} -> at
      nil -> nil
    end
  end
end
