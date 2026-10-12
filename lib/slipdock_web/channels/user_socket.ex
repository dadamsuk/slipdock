defmodule SlipdockWeb.UserSocket do
  @moduledoc """
  The websocket an API client keeps open to be told when something changed,
  rather than polling blind — today, a vault's sync (`SlipdockWeb.VaultChannel`).

  It authenticates with an API token, as the HTTP API does: connect to
  `/socket/websocket?token=<token>&vsn=2.0.0`. No token, or a dead one, and
  the connection is refused.
  """
  use Phoenix.Socket

  channel "vault:*", SlipdockWeb.VaultChannel

  @impl true
  def connect(%{"token" => token}, socket, connect_info) when is_binary(token) do
    ip = SlipdockWeb.ClientIP.from_connect_info(connect_info)

    case Slipdock.Accounts.get_api_token(String.trim(token), ip: ip) do
      {user, api_token} ->
        {:ok, socket |> assign(:current_user, user) |> assign(:api_token, api_token)}

      nil ->
        :error
    end
  end

  def connect(_params, _socket, _connect_info), do: :error

  @impl true
  def id(socket), do: "user_socket:#{socket.assigns.current_user.id}"
end
