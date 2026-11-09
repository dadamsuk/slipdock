defmodule SlipdockWeb.API.MachineJSON do
  @moduledoc """
  The one shape of a machine and of a pending enrolment (#2570) for every
  door that serializes them (MOD-12). Never the key or its hash.
  """

  alias Slipdock.Machines.{Enrolment, Machine}

  def machine(%Machine{} = m) do
    %{
      id: m.id,
      name: m.name,
      hostname: m.hostname,
      os: m.os,
      arch: m.arch,
      fingerprint: m.fingerprint,
      boards: m.board_ids,
      enrolled_via: m.enrolled_via,
      enrolled_at: m.inserted_at,
      last_seen_at: m.last_seen_at,
      revoked_at: m.revoked_at,
      state: if(Machine.revoked?(m), do: "revoked", else: "enrolled")
    }
  end

  @doc "What a person checks before approving: the machine as it described itself."
  def enrolment(%Enrolment{} = e) do
    %{
      hostname: e.hostname,
      os: e.os,
      arch: e.arch,
      fingerprint: e.fingerprint,
      client_ip: e.client_ip,
      asked_at: e.inserted_at,
      expires_at: e.expires_at,
      state:
        cond do
          e.approved_at -> "approved"
          e.denied_at -> "refused"
          true -> "pending"
        end
    }
  end
end
