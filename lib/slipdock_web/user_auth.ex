defmodule SlipdockWeb.UserAuth do
  @moduledoc "Session handling for browsers (cookie) and the API (bearer token)."
  use SlipdockWeb, :verified_routes

  import Plug.Conn
  import Phoenix.Controller

  alias Slipdock.Accounts

  @doc "Logs the user in: a fresh session with a 30-day session token."
  def log_in_user(conn, user) do
    token = Accounts.generate_session_token(user)
    return_to = get_session(conn, :user_return_to)

    conn
    |> renew_session()
    |> put_token_in_session(token)
    |> redirect(to: return_to || ~p"/")
  end

  defp renew_session(conn) do
    delete_csrf_token()
    conn |> configure_session(renew: true) |> clear_session()
  end

  def log_out_user(conn) do
    user_token = get_session(conn, :user_token)
    user_token && Accounts.delete_session_token(user_token)

    if live_socket_id = get_session(conn, :live_socket_id) do
      SlipdockWeb.Endpoint.broadcast(live_socket_id, "disconnect", %{})
    end

    conn
    |> renew_session()
    |> redirect(to: ~p"/login")
  end

  @doc "Plug: loads the current user from the session cookie, if any."
  def fetch_current_user(conn, _opts) do
    token = get_session(conn, :user_token)
    user = token && Accounts.get_user_by_session_token(token)
    assign(conn, :current_user, user)
  end

  @doc """
  Plug: loads the current user from an `Authorization: Bearer` API token if one
  is there, and carries on regardless. For endpoints that are readable without
  a token but say more with one.
  """
  def maybe_fetch_api_user(conn, _opts) do
    with ["Bearer " <> token] <- get_req_header(conn, "authorization"),
         {%Accounts.User{} = user, api_token} <- Accounts.get_api_token(String.trim(token)) do
      conn |> assign(:current_user, user) |> assign(:api_token, api_token)
    else
      _ -> conn |> assign(:current_user, nil) |> assign(:api_token, nil)
    end
  end

  @doc "Plug: loads the current user from an `Authorization: Bearer` API token, else 401."
  def fetch_api_user(conn, _opts) do
    with ["Bearer " <> token] <- get_req_header(conn, "authorization"),
         {%Accounts.User{} = user, api_token} <- Accounts.get_api_token(String.trim(token)) do
      conn |> assign(:current_user, user) |> assign(:api_token, api_token)
    else
      _ ->
        conn
        |> put_status(:unauthorized)
        |> json(%{
          error:
            "unauthorized: pass an API token as `Authorization: Bearer <token>` (create one at /account)"
        })
        |> halt()
    end
  end

  def require_authenticated_user(conn, _opts) do
    if conn.assigns[:current_user] do
      conn
    else
      conn
      |> put_flash(:info, "Please sign in to continue.")
      |> maybe_store_return_to()
      |> redirect(to: ~p"/login")
      |> halt()
    end
  end

  def redirect_if_user_is_authenticated(conn, _opts) do
    if conn.assigns[:current_user], do: conn |> redirect(to: ~p"/") |> halt(), else: conn
  end

  ## LiveView hooks

  def on_mount(:mount_current_user, _params, session, socket) do
    {:cont, mount_current_user(socket, session)}
  end

  def on_mount(:ensure_authenticated, _params, session, socket) do
    socket = mount_current_user(socket, session)

    if socket.assigns.current_user do
      {:cont, socket}
    else
      {:halt,
       socket
       |> Phoenix.LiveView.put_flash(:info, "Please sign in to continue.")
       |> Phoenix.LiveView.redirect(to: ~p"/login")}
    end
  end

  def on_mount(:redirect_if_user_is_authenticated, _params, session, socket) do
    socket = mount_current_user(socket, session)

    if socket.assigns.current_user,
      do: {:halt, Phoenix.LiveView.redirect(socket, to: ~p"/")},
      else: {:cont, socket}
  end

  defp mount_current_user(socket, session) do
    Phoenix.Component.assign_new(socket, :current_user, fn ->
      if token = session["user_token"], do: Accounts.get_user_by_session_token(token)
    end)
  end

  defp put_token_in_session(conn, token) do
    conn
    |> put_session(:user_token, token)
    |> put_session(:live_socket_id, "users_sessions:#{Base.url_encode64(token)}")
  end

  defp maybe_store_return_to(%{method: "GET"} = conn) do
    put_session(conn, :user_return_to, current_path(conn))
  end

  defp maybe_store_return_to(conn), do: conn
end
