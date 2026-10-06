defmodule SlipdockWeb.OAuth.RegistrationController do
  @moduledoc """
  Dynamic client registration (RFC 7591): `POST /oauth/register`.

  Open to anybody, as the RFC intends — claude.ai registers afresh on every new
  connection — so a registration grants nothing until a person approves it on
  the consent page. What guards it: the redirect URIs are checked strictly
  (`Slipdock.OAuth.Client`), and it is rate limited per IP. The limit is per
  minute rather than per hour because a hosted server sees every claude.ai
  user arrive from the same few addresses.

  What the client asks for beyond its name and redirect URIs is not up to the
  client: it is always a public client using the authorization-code grant with
  PKCE, and the response says so, which RFC 7591 §3.2.1 allows.
  """
  use SlipdockWeb, :controller

  alias Slipdock.OAuth
  alias Slipdock.RateLimit

  @registrations_per_minute 30

  def create(conn, params) do
    ip = SlipdockWeb.ClientIP.from_conn(conn)

    case RateLimit.hit("oauth:register:#{ip}", @registrations_per_minute, 60_000) do
      {:error, retry_in} ->
        conn
        |> put_resp_header("retry-after", Integer.to_string(retry_in))
        |> error(:too_many_requests, "slow_down", "too many registrations from here")

      :ok ->
        register(conn, params, ip)
    end
  end

  defp register(conn, params, ip) do
    with {:ok, uris} <- redirect_uris(params["redirect_uris"]),
         {:ok, name} <- client_name(params["client_name"]),
         {:ok, client} <-
           OAuth.register_client(%{client_name: name, redirect_uris: uris, registered_ip: ip}) do
      conn
      |> put_status(:created)
      |> put_resp_header("cache-control", "no-store")
      |> json(%{
        client_id: client.client_id,
        client_id_issued_at: DateTime.to_unix(client.inserted_at),
        client_name: client.client_name,
        redirect_uris: client.redirect_uris,
        grant_types: ["authorization_code", "refresh_token"],
        response_types: ["code"],
        token_endpoint_auth_method: "none"
      })
    else
      {:error, %Ecto.Changeset{} = changeset} ->
        {code, message} = changeset_error(changeset)
        error(conn, :bad_request, code, message)

      {:error, code, message} ->
        error(conn, :bad_request, code, message)
    end
  end

  defp redirect_uris(uris) when is_list(uris) and uris != [] do
    if Enum.all?(uris, &is_binary/1),
      do: {:ok, uris},
      else: {:error, "invalid_redirect_uri", "redirect_uris must be a list of strings"}
  end

  defp redirect_uris(_),
    do: {:error, "invalid_redirect_uri", "redirect_uris is required: a list of at least one"}

  defp client_name(nil), do: {:ok, nil}
  defp client_name(name) when is_binary(name), do: {:ok, name}

  defp client_name(_),
    do: {:error, "invalid_client_metadata", "client_name must be a string"}

  defp changeset_error(changeset) do
    {field, {message, _}} = hd(changeset.errors)
    code = if field == :redirect_uris, do: "invalid_redirect_uri", else: "invalid_client_metadata"
    {code, message}
  end

  defp error(conn, status, code, description) do
    conn |> put_status(status) |> json(%{error: code, error_description: description})
  end
end
