defmodule SlipdockWeb.API.MachineJSON do
  @moduledoc """
  The one shape of a machine and of a pending enrolment (#2570) for every
  door that serializes them (MOD-12). Never the key or its hash.
  """

  alias Slipdock.Machines.{Enrolment, Machine}
  alias Slipdock.Runners.{ConfigReport, MachineRunners, Runner}

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
      state: if(Machine.revoked?(m), do: "revoked", else: "enrolled"),
      ceiling: m.ceiling,
      ceiling_at: m.ceiling_at,
      config_version: m.config_version
    }
  end

  @doc "A machine with its runners and its log of config changes (#2571)."
  def machine_detail(%Machine{} = m) do
    runners =
      Enum.map(MachineRunners.list_runners(m), fn r ->
        outside =
          case MachineRunners.outside_ceiling(m, r) do
            :ok -> []
            {:error, reasons} -> reasons
          end

        Map.put(runner(r), :outside_ceiling, outside)
      end)

    m
    |> machine()
    |> Map.merge(%{runners: runners, changes: Enum.map(MachineRunners.reports(m), &report/1)})
  end

  @doc """
  A machine's runner (#2571): its pool, typed config and version, and what
  the daemon last said of it.
  """
  def runner(%Runner{} = r) do
    %{
      id: r.id,
      name: r.name,
      machine_id: r.machine_id,
      board_id: r.board_id,
      pool: r.pool,
      config: r.config,
      config_version: r.config_version,
      accepted_version: r.accepted_version,
      accepted_config: r.accepted_config,
      rejected_version: r.rejected_version,
      rejection: r.rejection,
      rejected_at: r.rejected_at,
      last_seen_at: r.last_seen_at,
      current_job_id: r.current_job_id
    }
  end

  @doc "One accepted or rejected change, from the machine's log."
  def report(%ConfigReport{} = r) do
    %{
      runner_id: r.runner_id,
      runner: r.runner_name,
      version: r.version,
      outcome: r.outcome,
      reason: r.reason,
      at: r.inserted_at
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
