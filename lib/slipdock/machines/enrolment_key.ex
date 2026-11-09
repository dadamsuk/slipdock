defmodule Slipdock.Machines.EnrolmentKey do
  @moduledoc """
  A one-time enrolment key (#2570): made by a machine's owner-to-be, on the
  account page or with the API or CLI, for a machine with nobody at its
  screen (`slipdock-runner init --key sde_…`). It names the boards the
  machine will serve, works once, and lapses after a day. Only its hash is
  kept; the key is shown once.
  """
  use Ecto.Schema

  @validity_hours 24

  schema "machine_enrolment_keys" do
    field :key_hash, :binary, redact: true
    field :label, :string
    field :board_ids, {:array, :integer}, default: []
    field :expires_at, :utc_datetime
    field :used_at, :utc_datetime
    belongs_to :user, Slipdock.Accounts.User
    belongs_to :machine, Slipdock.Machines.Machine
    timestamps(type: :utc_datetime, updated_at: false)
  end

  def validity_hours, do: @validity_hours
end
