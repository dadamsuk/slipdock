defmodule SlipdockWeb.API.MachineController do
  @moduledoc """
  Machines over the API (#2570, `Slipdock.Machines`). Three kinds of caller:

  - **A daemon enrolling** (`enrol`, `token`): anonymous, because these are
    how a machine gets its key. Guarded the way the device flow is: the
    device code is 32 random bytes, the user code short-lived and single
    use, and both starting and polling rate limited per address.
  - **An enrolled machine** (`me`, and since #2571 `config`, `ceiling` and
    `report`): its machine key as the bearer, and only here and on the
    runner protocol for its own runners. The machine key is not an API
    token, so every other route refuses it.
  - **The owner** (`index`, `show`, `create_key`, `revoke`, a machine's
    runners with `add_runner`, `set_runner`, `remove_runner`, `pause_runner` and
    `resume_runner`, `request_update`, and looking up
    and deciding an enrolment by its code, `enrolment`, `approve` and `refuse`, as the
    approval page does): an API token.
    Machines are account-wide, so a token confined to some boards is
    refused them, and says so (ARCH-8).
  """
  use SlipdockWeb, :controller

  alias Slipdock.Machines
  alias Slipdock.Machines.{Enrolment, EnrolmentKey, Machine}
  alias Slipdock.Runners.{MachineRunners, MachineSetup, Probe}
  alias SlipdockWeb.API.MachineJSON
  alias Slipdock.RateLimit

  @poll_interval_seconds 5
  @starts_per_hour 20
  @polls_per_minute 30
  @default_config_wait 25
  @max_config_wait 50

  plug :refuse_board_scoped_token
       when action in [
              :index,
              :show,
              :create_key,
              :rename,
              :revoke,
              :enrolment,
              :approve,
              :refuse,
              :add_runner,
              :set_runner,
              :remove_runner,
              :pause_runner,
              :resume_runner,
              :request_update
            ]

  ## A daemon enrolling ----------------------------------------------------------

  @doc """
  POST /api/machines/enrol — start a device-code enrolment, naming the
  machine (`hostname`, `os`, `arch`, `fingerprint`).
  """
  def enrol(conn, params) do
    ip = SlipdockWeb.ClientIP.from_conn(conn)

    with :ok <- limit(conn, "machine:start:#{ip}", @starts_per_hour, 3_600_000),
         {:ok, {device_code, enrolment}} <- Machines.request_enrolment(params, ip) do
      shown = Slipdock.Accounts.DeviceAuthorization.display_code(enrolment.user_code)

      json(conn, %{
        device_code: device_code,
        user_code: shown,
        verification_uri: url(~p"/account/machines/approve"),
        verification_uri_complete: url(~p"/account/machines/approve?#{[user_code: shown]}"),
        expires_in: Enrolment.validity_minutes() * 60,
        interval: @poll_interval_seconds
      })
    else
      {:error, :invalid, message} -> error(conn, :bad_request, "invalid_request", message)
      %Plug.Conn{} = limited -> limited
    end
  end

  @doc """
  POST /api/machines/enrol/token — collect the machine key: with the
  `device_code` once a person has approved, or at once with a one-time
  `enrolment_key` and the machine's description.
  """
  def token(conn, %{"device_code" => device_code}) when is_binary(device_code) do
    ip = SlipdockWeb.ClientIP.from_conn(conn)

    with :ok <- limit(conn, "machine:poll:#{ip}", @polls_per_minute, 60_000) do
      case Machines.poll_enrolment(device_code) do
        {:ok, {key, machine}} ->
          enrolled(conn, key, machine)

        {:error, :authorization_pending} ->
          error(conn, :bad_request, "authorization_pending", "nobody has approved it yet")

        {:error, :access_denied} ->
          error(conn, :bad_request, "access_denied", "the enrolment was refused")

        {:error, _} ->
          # Unknown and expired get one answer, so polling can't find codes.
          error(conn, :bad_request, "expired_token", "the code expired — run init again")
      end
    end
  end

  def token(conn, %{"enrolment_key" => key} = params) when is_binary(key) do
    ip = SlipdockWeb.ClientIP.from_conn(conn)

    with :ok <- limit(conn, "machine:poll:#{ip}", @polls_per_minute, 60_000) do
      case Machines.enrol_with_key(key, params) do
        {:ok, {machine_key, machine}} ->
          enrolled(conn, machine_key, machine)

        {:error, :invalid, message} ->
          error(conn, :bad_request, "invalid_request", message)

        {:error, _} ->
          error(
            conn,
            :bad_request,
            "invalid_grant",
            "that enrolment key is unknown, used or lapsed — make another on the account's Machines page"
          )
      end
    end
  end

  def token(conn, _params),
    do:
      error(
        conn,
        :bad_request,
        "invalid_request",
        "pass the device_code you were given, or an enrolment_key"
      )

  defp enrolled(conn, key, machine) do
    json(conn, %{machine_key: key, machine: MachineJSON.machine(machine)})
  end

  ## An enrolled machine ---------------------------------------------------------

  @doc "GET /api/machine — the machine its key belongs to."
  def me(conn, _params) do
    with {:ok, machine} <- machine_key(conn) do
      json(conn, %{machine: MachineJSON.machine(machine)})
    end
  end

  @doc """
  GET /api/machine/setup-prompt — *Set up this machine with Claude* (#2579):
  the prompt `slipdock-runner init` (and `setup`) launches Claude with.
  """
  def machine_setup_prompt(conn, _params) do
    with {:ok, machine} <- machine_key(conn) do
      json(conn, %{prompt: MachineSetup.prompt(machine, SlipdockWeb.BaseURL.from_conn(conn))})
    end
  end

  @doc """
  GET /api/machine/config?version=N&wait=S — the daemon's long-poll (#2571):
  its runners' typed configs and the machine's config version, at once when
  the version is above `N` (or no `N` is given), else as soon as it changes,
  or 204 after `S` seconds (at most #{@max_config_wait}) with no change.
  """
  def config(conn, params) do
    with {:ok, machine} <- machine_key(conn) do
      since = int(params["version"], -1)
      wait = params["wait"] |> int(@default_config_wait) |> max(0) |> min(@max_config_wait)

      case MachineRunners.wait_for_config(machine, since, wait * 1000) do
        nil -> send_resp(conn, :no_content, "")
        config -> json(conn, config)
      end
    end
  end

  @doc """
  PUT /api/machine/ceiling — the daemon reports its machine's ceiling, from
  the machine's own local file (#2571). Kept to show; the server never sets it.
  """
  def ceiling(conn, params) do
    with {:ok, machine} <- machine_key(conn) do
      case MachineRunners.record_ceiling(machine, Map.get(params, "ceiling", params)) do
        {:ok, machine} -> json(conn, %{machine: MachineJSON.machine(machine)})
        {:error, :invalid, message} -> unprocessable(conn, message)
      end
    end
  end

  @doc """
  POST /api/machine/runners/:runner_id/report — the daemon says what it did
  with a runner's config at `version`: `outcome` `accepted`, or `rejected`
  with a `reason` (#2571). A stale version answers 409 with the current one.
  """
  def report(conn, %{"runner_id" => runner_id} = params) do
    with {:ok, machine} <- machine_key(conn) do
      case MachineRunners.machine_runner(machine, runner_id) do
        nil -> conn |> put_status(:not_found) |> json(%{error: "no such runner on this machine"})
        runner -> reported(conn, MachineRunners.report(machine, runner, params), params)
      end
    end
  end

  defp reported(conn, {:ok, runner}, _params),
    do: json(conn, %{runner: MachineJSON.runner(runner)})

  defp reported(conn, {:error, :stale, current}, params) do
    conn
    |> put_status(:conflict)
    |> json(%{
      error: "version #{params["version"]} is not the runner's current config",
      config_version: current
    })
  end

  defp reported(conn, {:error, :invalid, message}, _params), do: unprocessable(conn, message)

  # The machine key (`Bearer sdm_…`), and only that: it is not an API token.
  defp machine_key(conn) do
    key =
      case get_req_header(conn, "authorization") do
        ["Bearer " <> key | _] -> key
        _ -> nil
      end

    case Machines.authenticate(key, SlipdockWeb.ClientIP.from_conn(conn)) do
      %Machine{} = machine ->
        {:ok, machine}

      nil ->
        conn
        |> put_status(:unauthorized)
        |> json(%{
          error:
            "unauthorized: pass the machine key as `Authorization: Bearer sdm_…` " <>
              "(a revoked machine's key no longer works)"
        })
    end
  end

  defp int(value, default) do
    case Integer.parse(to_string(value || "")) do
      {n, ""} -> n
      _ -> default
    end
  end

  ## The owner -------------------------------------------------------------------

  @doc """
  GET /api/machines — your machines, and (`shared`) the machines serving a
  board you're a member of, which you see but don't change (#2572).
  """
  def index(conn, _params) do
    user = conn.assigns.current_user

    json(conn, %{
      machines: user |> Machines.list_machines() |> Enum.map(&MachineJSON.machine/1),
      shared: user |> Machines.list_shared_machines() |> Enum.map(&MachineJSON.machine/1)
    })
  end

  @doc """
  GET /api/machines/:id — with its ceiling, runners and log of config
  changes; yours, or one serving a board you're a member of (`yours` says
  which).
  """
  def show(conn, %{"id" => id}) do
    case Machines.get_visible_machine(conn.assigns.current_user, id) do
      {:ok, machine, :owner} ->
        json(conn, %{machine: Map.put(MachineJSON.machine_detail(machine), :yours, true)})

      {:ok, machine, :member} ->
        boards =
          conn.assigns.current_user
          |> Slipdock.Access.list_boards(archived: :all)
          |> Enum.map(& &1.id)

        detail = MachineJSON.machine_detail(machine, boards: boards)
        json(conn, %{machine: Map.put(detail, :yours, false)})

      {:error, :not_found, _} ->
        not_found(conn)
    end
  end

  @doc """
  POST /api/machines/:id/runners/:runner_id/pause (or …/resume) — a paused
  runner is handed no job until it is resumed (#2572).
  """
  def pause_runner(conn, params), do: pause_or_resume(conn, params, :pause_runner)

  @doc false
  def resume_runner(conn, params), do: pause_or_resume(conn, params, :resume_runner)

  defp pause_or_resume(conn, %{"id" => id, "runner_id" => runner_id}, action) do
    with {:ok, machine} <- fetch(conn, id),
         {:ok, runner} <- fetch_runner(conn, machine, runner_id) do
      case apply(MachineRunners, action, [runner]) do
        {:ok, runner} -> json(conn, %{runner: MachineJSON.runner(runner)})
        {:error, :invalid, message} -> unprocessable(conn, message)
      end
    end
  end

  @doc """
  POST /api/machines/:id/runners/:runner_id/probe — send the runner a probe
  (#2580): it checks its setup and runs its probe hook. A probe already on
  its way is answered rather than a second (200, else 201).
  """
  def probe(conn, %{"id" => id, "runner_id" => runner_id}) do
    with {:ok, machine} <- fetch(conn, id),
         {:ok, runner} <- fetch_runner(conn, machine, runner_id) do
      open = Probe.latest([runner])[runner.id]

      case Probe.send_probe(machine, runner) do
        {:ok, %{id: same} = job} when is_map(open) and open.id == same ->
          json(conn, %{probe: MachineJSON.probe(job)})

        {:ok, job} ->
          conn |> put_status(:created) |> json(%{probe: MachineJSON.probe(job)})

        {:error, :invalid, message} ->
          unprocessable(conn, message)
      end
    end
  end

  @doc """
  GET /api/machines/:id/runners/:runner_id/probe — the runner's latest probe
  (#2580), or `probe: null`; for its owner, and for a member of the
  runner's board.
  """
  def show_probe(conn, %{"id" => id, "runner_id" => runner_id}) do
    with {:ok, machine, role} <- fetch_visible(conn, id),
         {:ok, runner} <- fetch_runner(conn, machine, runner_id),
         :ok <- runner_visible(conn, role, runner) do
      probe = Probe.latest([runner])[runner.id]
      json(conn, %{probe: probe && MachineJSON.probe(probe)})
    end
  end

  # A machine its owner or a member of one of its boards may read.
  defp fetch_visible(conn, id) do
    case Machines.get_visible_machine(conn.assigns.current_user, id) do
      {:ok, machine, role} -> {:ok, machine, role}
      {:error, :not_found, _} -> not_found(conn)
    end
  end

  # A member reads only the runners of boards they can read (#2572).
  defp runner_visible(_conn, :owner, _runner), do: :ok

  defp runner_visible(conn, :member, runner) do
    board = Slipdock.Boards.get_board_record!(runner.board_id)

    if Slipdock.Access.can_read?(
         Slipdock.Access.board_permission(conn.assigns.current_user, board)
       ),
       do: :ok,
       else: conn |> put_status(:not_found) |> json(%{error: "no such runner on this machine"})
  end

  @doc """
  GET /api/machines/:id/setup-prompt — *Set up this machine with Claude*
  (#2579), to paste into Claude Code on the machine; its owner's alone.
  """
  def setup_prompt(conn, %{"id" => id}) do
    with {:ok, machine} <- fetch(conn, id) do
      json(conn, %{prompt: MachineSetup.prompt(machine, SlipdockWeb.BaseURL.from_conn(conn))})
    end
  end

  @doc """
  POST /api/machines/:id/update — *update now*: the daemon looks for a newer
  signed release at once (#2572).
  """
  def request_update(conn, %{"id" => id}) do
    with {:ok, machine} <- fetch(conn, id) do
      case MachineRunners.request_update(machine) do
        {:ok, machine} -> json(conn, %{machine: MachineJSON.machine(machine)})
        {:error, :invalid, message} -> unprocessable(conn, message)
      end
    end
  end

  @doc """
  POST /api/machines/:id/runners — add a runner to the machine (#2571):
  `board` (one it serves), `pool`, optional `name`, and its typed `config`.
  """
  def add_runner(conn, %{"id" => id} = params) do
    with {:ok, machine} <- fetch(conn, id),
         {:ok, board} <- serving_board(conn, machine, params["board"]) do
      case MachineRunners.add_runner(machine, board, params) do
        {:ok, runner} ->
          conn |> put_status(:created) |> json(%{runner: MachineJSON.runner(runner)})

        {:error, :invalid, message} ->
          unprocessable(conn, message)
      end
    end
  end

  @doc """
  PATCH /api/machines/:id/runners/:runner_id — change a runner's `pool`,
  `name` or any of its `config` fields; the daemon has it within seconds.
  """
  def set_runner(conn, %{"id" => id, "runner_id" => runner_id} = params) do
    with {:ok, machine} <- fetch(conn, id),
         {:ok, runner} <- fetch_runner(conn, machine, runner_id) do
      case MachineRunners.set_runner(runner, params) do
        {:ok, runner} -> json(conn, %{runner: MachineJSON.runner(runner)})
        {:error, :invalid, message} -> unprocessable(conn, message)
      end
    end
  end

  @doc "DELETE /api/machines/:id/runners/:runner_id — the daemon finishes its job, then stops it."
  def remove_runner(conn, %{"id" => id, "runner_id" => runner_id}) do
    with {:ok, machine} <- fetch(conn, id),
         {:ok, runner} <- fetch_runner(conn, machine, runner_id),
         {:ok, runner} <- MachineRunners.remove_runner(runner) do
      json(conn, %{removed: MachineJSON.runner(runner)})
    end
  end

  defp fetch_runner(conn, machine, ref) do
    case MachineRunners.get_runner(machine, ref) do
      {:ok, runner} ->
        {:ok, runner}

      {:error, :not_found, _} ->
        conn |> put_status(:not_found) |> json(%{error: "no such runner on this machine"})
    end
  end

  # One of the boards the machine serves that its owner can still reach.
  defp serving_board(conn, machine, ref) do
    with {:ok, [board_id]} <- Machines.servable_board_ids(conn.assigns.current_user, [ref || ""]),
         true <- Enum.member?(machine.board_ids, board_id) do
      {:ok, Slipdock.Boards.get_board_record!(board_id)}
    else
      false ->
        unprocessable(conn, "the machine doesn't serve that board: choose one of its boards")

      {:error, :invalid, message} ->
        unprocessable(conn, message)
    end
  end

  defp unprocessable(conn, message),
    do: conn |> put_status(:unprocessable_entity) |> json(%{error: message})

  @doc "POST /api/machines/enrolment-keys — a one-time key for `boards`, shown once."
  def create_key(conn, params) do
    case Machines.create_enrolment_key(
           conn.assigns.current_user,
           params["boards"],
           params["label"]
         ) do
      {:ok, key, record} ->
        conn
        |> put_status(:created)
        |> json(%{
          enrolment_key: key,
          boards: record.board_ids,
          label: record.label,
          expires_at: record.expires_at,
          valid_hours: EnrolmentKey.validity_hours()
        })

      {:error, :invalid, message} ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: message})
    end
  end

  @doc """
  PATCH /api/machines/:id — rename it (#2666): `name`, what the pages, the
  CLI and the board show. The hostname it reported is kept as it was.
  """
  def rename(conn, %{"id" => id} = params) do
    with {:ok, machine} <- fetch(conn, id) do
      case Machines.rename_machine(machine, params["name"]) do
        {:ok, machine} -> json(conn, %{machine: MachineJSON.machine(machine)})
        {:error, :invalid, message} -> unprocessable(conn, message)
      end
    end
  end

  @doc "DELETE /api/machines/:id — revoke it: its key stops working at once."
  def revoke(conn, %{"id" => id}) do
    with {:ok, machine} <- fetch(conn, id),
         {:ok, machine} <- Machines.revoke_machine(machine) do
      json(conn, %{machine: MachineJSON.machine(machine)})
    end
  end

  @doc """
  GET /api/machines/enrolment?user_code=… — the machine a code belongs to,
  as the approval page shows it, so it can be checked before deciding.
  """
  def enrolment(conn, params) do
    with {:ok, enrolment} <- pending(conn, params["user_code"]) do
      json(conn, %{enrolment: MachineJSON.enrolment(enrolment)})
    end
  end

  @doc """
  POST /api/machines/enrolment/approve (with `boards`) or …/refuse — decide
  a pending enrolment by its `user_code`, as the approval page does. The
  approver becomes the machine's owner.
  """
  def approve(conn, params), do: decide(conn, "approve", params)

  @doc false
  def refuse(conn, params), do: decide(conn, "refuse", params)

  defp decide(conn, decision, params) do
    with {:ok, enrolment} <- pending(conn, params["user_code"]) do
      result =
        if decision == "approve",
          do: Machines.approve_enrolment(enrolment, conn.assigns.current_user, params["boards"]),
          else: Machines.deny_enrolment(enrolment)

      case result do
        {:ok, decided} ->
          json(conn, %{enrolment: MachineJSON.enrolment(decided)})

        {:error, :invalid, message} ->
          conn |> put_status(:unprocessable_entity) |> json(%{error: message})

        {:error, :expired} ->
          gone(conn)
      end
    end
  end

  # Per person, as on the page: the code is short.
  defp pending(conn, code) do
    key = "machine:lookup:#{conn.assigns.current_user.id}"

    with :ok <- limit(conn, key, 30, 3_600_000) do
      case Machines.enrolment_by_user_code(code) do
        nil -> gone(conn)
        enrolment -> {:ok, enrolment}
      end
    end
  end

  defp gone(conn) do
    conn
    |> put_status(:not_found)
    |> json(%{
      error:
        "no pending machine with that code: codes last 10 minutes and work once " <>
          "(run slipdock-runner init again)"
    })
  end

  # A machine to change: its owner's alone. A member of a board it serves
  # sees it (`show`) but is told only the owner changes it.
  defp fetch(conn, id) do
    case Machines.get_visible_machine(conn.assigns.current_user, id) do
      {:ok, machine, :owner} ->
        {:ok, machine}

      {:ok, _machine, :member} ->
        conn
        |> put_status(:forbidden)
        |> json(%{error: "only the machine's owner changes it; you can see it as a board member"})

      {:error, :not_found, _} ->
        not_found(conn)
    end
  end

  defp not_found(conn), do: conn |> put_status(:not_found) |> json(%{error: "machine not found"})

  defp refuse_board_scoped_token(conn, _opts) do
    case conn.assigns[:api_token] do
      %{scope_boards: [_ | _]} ->
        conn
        |> put_status(:forbidden)
        |> json(%{
          error:
            "this API token is limited to some boards, so it can't manage machines: " <>
              "they belong to the account (use a token without a board limit)"
        })
        |> halt()

      _ ->
        conn
    end
  end

  defp limit(conn, key, count, window) do
    case RateLimit.hit(key, count, window) do
      :ok -> :ok
      {:error, _} -> error(conn, :too_many_requests, "slow_down", "too many requests from here")
    end
  end

  defp error(conn, status, code, description),
    do: conn |> put_status(status) |> json(%{error: code, error_description: description})
end
