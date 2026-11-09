defmodule Slipdock.Machines.Machine do
  @moduledoc """
  A computer running the runner daemon (#2570, W-2544 §1), bound to the
  account that approved its enrolment: its one owner (W-2541).

  It authenticates with its own **machine key** (`sdm_…`), never an API
  token: only the key's hash is kept, and the key is handed over once, when
  the enrolment completes. A machine key is not accepted anywhere an API
  token is. `board_ids` are the top-level boards the owner chose for it to
  serve. A revoked machine keeps its row (the record of what it was), but its
  key stops working at once.
  """
  use Ecto.Schema

  schema "machines" do
    field :name, :string
    field :hostname, :string
    field :os, :string
    field :arch, :string
    field :fingerprint, :string
    field :key_hash, :binary, redact: true
    field :board_ids, {:array, :integer}, default: []
    # "device_code" or "enrolment_key".
    field :enrolled_via, :string
    field :last_seen_at, :utc_datetime
    field :last_seen_ip, :string
    field :revoked_at, :utc_datetime

    belongs_to :user, Slipdock.Accounts.User

    timestamps(type: :utc_datetime)
  end

  def revoked?(%__MODULE__{revoked_at: at}), do: not is_nil(at)
end
