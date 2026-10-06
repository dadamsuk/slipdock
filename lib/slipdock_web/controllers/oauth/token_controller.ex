defmodule SlipdockWeb.OAuth.TokenController do
  @moduledoc """
  `POST /oauth/token`: a client trades an authorization code for a token, or
  renews one with its refresh token. Form-encoded, as RFC 6749 requires (JSON
  is read too, since the endpoint parses both).

  Clients are public, so a client authenticates with nothing but its
  `client_id`; what proves the request is theirs is the PKCE verifier for a
  code, and possession of the refresh token for a renewal.
  """
  use SlipdockWeb, :controller

  alias Slipdock.OAuth

  def create(conn, %{"grant_type" => "authorization_code"} = params) do
    params |> OAuth.exchange_code(SlipdockWeb.BaseURL.from_conn(conn)) |> respond(conn)
  end

  def create(conn, %{"grant_type" => "refresh_token"} = params) do
    params |> OAuth.refresh() |> respond(conn)
  end

  def create(conn, %{"grant_type" => _}) do
    respond(
      {:error, "unsupported_grant_type", "use authorization_code or refresh_token"},
      conn
    )
  end

  def create(conn, _params),
    do: respond({:error, "invalid_request", "grant_type is required"}, conn)

  defp respond(result, conn) do
    conn =
      conn
      |> put_resp_header("cache-control", "no-store")
      |> put_resp_header("pragma", "no-cache")

    case result do
      {:ok, body} ->
        json(conn, body)

      # RFC 6749 §5.2: a client that fails to authenticate gets a 401.
      {:error, "invalid_client" = code, description} ->
        conn |> put_status(:unauthorized) |> json(%{error: code, error_description: description})

      {:error, code, description} ->
        conn |> put_status(:bad_request) |> json(%{error: code, error_description: description})
    end
  end
end
