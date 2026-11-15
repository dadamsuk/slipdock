defmodule SlipdockWeb.GoogleController do
  @moduledoc """
  Connecting a Google Drive (W-1690): off to Google's consent screen, back
  with a code, and disconnecting. Account › Preferences links here; the
  work is `Slipdock.Google`'s.

  The `state` sent to Google is random and kept in the session, and the code
  is only traded when the two match, so a link somebody else crafted cannot
  attach their Drive to your account.
  """
  use SlipdockWeb, :controller

  alias Slipdock.Google

  @state_key "google_oauth_state"
  @back "/account/settings#google-drive"

  def connect(conn, _params) do
    if Google.configured?() do
      state = Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)

      conn
      |> put_session(@state_key, state)
      |> redirect(external: Google.authorize_url(state, redirect_uri()))
    else
      not_configured(conn)
    end
  end

  def callback(conn, params) do
    expected = get_session(conn, @state_key)
    conn = delete_session(conn, @state_key)

    cond do
      not Google.configured?() ->
        not_configured(conn)

      not (is_binary(expected) and is_binary(params["state"]) and
               Plug.Crypto.secure_compare(expected, params["state"])) ->
        back(
          conn,
          :error,
          "That Google sign-in didn't come from this page. Try connecting again."
        )

      params["error"] == "access_denied" ->
        back(conn, :info, "Google Drive was not connected.")

      is_binary(params["error"]) ->
        back(conn, :error, "Google said no: #{params["error"]}.")

      true ->
        connected(conn, Google.connect(conn.assigns.current_user, params["code"], redirect_uri()))
    end
  end

  defp connected(conn, {:ok, connection}),
    do: back(conn, :info, "Google Drive connected#{as(connection.email)}.")

  defp connected(conn, {:error, :invalid_grant}),
    do: back(conn, :error, "Google turned down that sign-in. Try connecting again.")

  # The context's refusal (`Slipdock.Policy`): somebody else's connection.
  defp connected(conn, {:error, %Slipdock.Policy.Refused{message: message}}),
    do: back(conn, :error, message)

  defp connected(conn, {:error, message}) when is_binary(message),
    do: back(conn, :error, message)

  def disconnect(conn, _params) do
    case Google.disconnect(conn.assigns.current_user) do
      :ok -> back(conn, :info, "Google Drive disconnected.")
      {:error, %Slipdock.Policy.Refused{message: message}} -> back(conn, :error, message)
    end
  end

  defp as(nil), do: ""
  defp as(email), do: " as " <> email

  defp not_configured(conn),
    do: back(conn, :error, "Google Drive isn't set up on this server.")

  defp back(conn, kind, message), do: conn |> put_flash(kind, message) |> redirect(to: @back)

  # Fixed rather than taken from the request: Google only sends people back
  # to the address registered with the client, which is the server's own.
  defp redirect_uri, do: Slipdock.Automations.Runner.base_url() <> "/account/google/callback"
end
