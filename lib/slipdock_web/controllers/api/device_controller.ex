defmodule SlipdockWeb.API.DeviceController do
  @moduledoc """
  The device authorization grant (RFC 8628), for a client that cannot host a
  browser — an agent on a laptop, in a sandbox, or anywhere that is not this
  server.

  These two endpoints are how a client *gets* a token, so neither can sit
  behind one. What protects them instead: the device code is 32 random bytes,
  the user code expires in minutes and is good once, and both creating and
  polling are rate limited per IP so neither can be used to spam approval
  prompts or to grind at codes.
  """
  use SlipdockWeb, :controller

  alias Slipdock.Accounts
  alias Slipdock.Accounts.DeviceAuthorization
  alias Slipdock.RateLimit

  # Deliberately matched to what the client is told to wait.
  @poll_interval_seconds 5
  @starts_per_hour 20
  @polls_per_minute 30

  @doc "POST /api/auth/device — begin a request."
  def create(conn, params) do
    ip = client_ip(conn)

    case RateLimit.hit("device:start:#{ip}", @starts_per_hour, 3_600_000) do
      {:error, _retry_in} ->
        error(conn, :too_many_requests, "slow_down", "too many device requests from here")

      :ok ->
        %{
          scope: params["scope"],
          scope_boards: board_ids(params["scope_boards"]),
          client_label: label(params["label"]),
          client_ip: ip,
          client_agent: conn |> get_req_header("user-agent") |> List.first()
        }
        |> Accounts.request_device_authorization()
        |> started(conn)
    end
  end

  defp started({:error, :admin_scope}, conn) do
    error(
      conn,
      :bad_request,
      "invalid_scope",
      "the admin scope can't be asked for this way — an admin makes that token " <>
        "themselves, under Account → API tokens"
    )
  end

  defp started({device_code, request}, conn) do
    shown = DeviceAuthorization.display_code(request.user_code)

    json(conn, %{
      device_code: device_code,
      user_code: shown,
      verification_uri: url(~p"/activate"),
      verification_uri_complete: url(~p"/activate?#{[user_code: shown]}"),
      expires_in: DeviceAuthorization.validity_minutes() * 60,
      interval: @poll_interval_seconds
    })
  end

  @doc "POST /api/auth/device/token — poll until a person decides."
  def token(conn, %{"device_code" => device_code}) do
    ip = client_ip(conn)

    case RateLimit.hit("device:poll:#{ip}", @polls_per_minute, 60_000) do
      {:error, _retry_in} ->
        error(conn, :too_many_requests, "slow_down", "polling faster than the interval given")

      :ok ->
        case Accounts.poll_device_authorization(device_code) do
          {:ok, token} ->
            json(conn, %{token: token, token_type: "bearer"})

          {:error, :authorization_pending} ->
            error(conn, :bad_request, "authorization_pending", "nobody has approved it yet")

          {:error, :access_denied} ->
            error(conn, :bad_request, "access_denied", "the request was refused")

          {:error, :expired_token} ->
            error(conn, :bad_request, "expired_token", "the code expired — start again")

          {:error, _} ->
            # An unknown code gets the same answer a wrong one does, so polling
            # cannot be used to find out which codes exist.
            error(conn, :bad_request, "expired_token", "the code expired — start again")
        end
    end
  end

  def token(conn, _params),
    do: error(conn, :bad_request, "invalid_request", "pass the device_code you were given")

  defp error(conn, status, code, description) do
    conn |> put_status(status) |> json(%{error: code, error_description: description})
  end

  defp label(value) do
    case value |> to_string() |> String.trim() |> String.slice(0, 60) do
      "" -> nil
      text -> text
    end
  end

  defp board_ids(ids) when is_list(ids) do
    Enum.flat_map(ids, fn
      id when is_integer(id) ->
        [id]

      id when is_binary(id) ->
        case Integer.parse(id) do
          {n, ""} -> [n]
          _ -> []
        end

      _ ->
        []
    end)
  end

  defp board_ids(_), do: []

  defp client_ip(conn) do
    case get_req_header(conn, "x-forwarded-for") do
      [value | _] -> value |> String.split(",") |> List.first() |> String.trim()
      [] -> conn.remote_ip |> :inet.ntoa() |> to_string()
    end
  end
end
