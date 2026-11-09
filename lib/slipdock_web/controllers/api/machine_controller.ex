defmodule SlipdockWeb.API.MachineController do
  @moduledoc """
  Machines over the API (#2570, `Slipdock.Machines`). Three kinds of caller:

  - **A daemon enrolling** (`enrol`, `token`): anonymous, because these are
    how a machine gets its key. Guarded the way the device flow is: the
    device code is 32 random bytes, the user code short-lived and single
    use, and both starting and polling rate limited per address.
  - **An enrolled machine** (`me`): its machine key as the bearer, and only
    here. The machine key is not an API token, so every other route refuses
    it.
  - **The owner** (`index`, `show`, `create_key`, `revoke`, and looking up
    and deciding an enrolment by its code, `enrolment`, `approve` and `refuse`, as the
    approval page does): an API token.
    Machines are account-wide, so a token confined to some boards is
    refused them, and says so (ARCH-8).
  """
  use SlipdockWeb, :controller

  alias Slipdock.Machines
  alias Slipdock.Machines.{Enrolment, EnrolmentKey, Machine}
  alias SlipdockWeb.API.MachineJSON
  alias Slipdock.RateLimit

  @poll_interval_seconds 5
  @starts_per_hour 20
  @polls_per_minute 30

  plug :refuse_board_scoped_token
       when action in [:index, :show, :create_key, :revoke, :enrolment, :approve, :refuse]

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
    key =
      case get_req_header(conn, "authorization") do
        ["Bearer " <> key | _] -> key
        _ -> nil
      end

    case Machines.authenticate(key, SlipdockWeb.ClientIP.from_conn(conn)) do
      %Machine{} = machine ->
        json(conn, %{machine: MachineJSON.machine(machine)})

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

  ## The owner -------------------------------------------------------------------

  @doc "GET /api/machines — your machines."
  def index(conn, _params) do
    json(conn, %{
      machines:
        conn.assigns.current_user |> Machines.list_machines() |> Enum.map(&MachineJSON.machine/1)
    })
  end

  @doc "GET /api/machines/:id"
  def show(conn, %{"id" => id}) do
    with {:ok, machine} <- fetch(conn, id) do
      json(conn, %{machine: MachineJSON.machine(machine)})
    end
  end

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

  defp fetch(conn, id) do
    case SlipdockWeb.Params.id(id) do
      nil ->
        not_found(conn)

      id ->
        with {:error, :not_found, _} <- Machines.get_machine(conn.assigns.current_user, id),
             do: not_found(conn)
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
