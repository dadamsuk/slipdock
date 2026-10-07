defmodule SlipdockWeb.ClientIP do
  @moduledoc """
  The address a request really came from, for rate limits and audit trails.

  Behind a reverse proxy the peer is the proxy, and the visitor is in
  `X-Forwarded-For`. But anybody can send that header, so it is believed only
  when the peer is a proxy this server trusts — and then read from the right,
  skipping further trusted hops, because each proxy appends what it saw and
  only the leftmost entries are under the client's control.

  Get this wrong one way and a stranger picks their own address, dodging every
  per-IP limit and forging the "asked from" an approver reads. Get it wrong the
  other way and everybody behind the proxy shares one address, so one person
  can use up the sign-in limit for the whole server.

  Trusted proxies are `config :slipdock, :trusted_proxies`, a list of CIDRs
  (`SLIPDOCK_TRUSTED_PROXIES` in the environment). The default is loopback and
  the private ranges, which covers a proxy on the same host or in the same
  Docker network; a server exposed directly to an untrusted LAN should narrow it.
  """

  @default_trusted ~w(127.0.0.0/8 ::1/128 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 fc00::/7)

  @doc "The client address of a plug request, as a string."
  @spec from_conn(Plug.Conn.t()) :: String.t()
  def from_conn(%Plug.Conn{} = conn) do
    conn.remote_ip
    |> resolve(Plug.Conn.get_req_header(conn, "x-forwarded-for"))
    |> format()
  end

  @doc """
  The client address of a LiveView, as a string. Only works during `mount/3`,
  and needs `:peer_data` and `:x_headers` in the socket's `connect_info`.
  """
  @spec from_socket(Phoenix.LiveView.Socket.t()) :: String.t()
  def from_socket(socket) do
    case Phoenix.LiveView.get_connect_info(socket, :peer_data) do
      %{address: address} ->
        forwarded =
          for {"x-forwarded-for", value} <-
                Phoenix.LiveView.get_connect_info(socket, :x_headers) || [],
              do: value

        address |> resolve(forwarded) |> format()

      _ ->
        "unknown"
    end
  end

  @doc """
  The client address given the peer (a tuple) and every `X-Forwarded-For`
  value the request carried, in order.
  """
  @spec resolve(:inet.ip_address(), [String.t()]) :: :inet.ip_address()
  def resolve(peer, forwarded) do
    if trusted?(peer) do
      forwarded
      |> Enum.flat_map(&String.split(&1, ","))
      |> Enum.reverse()
      |> walk(peer)
    else
      peer
    end
  end

  # Right to left: the first hop that is not one of ours is the client. A hop
  # that does not parse ends the walk at the last address a trusted proxy vouched for.
  defp walk([], last), do: last

  defp walk([hop | rest], last) do
    case parse(hop) do
      {:ok, address} -> if trusted?(address), do: walk(rest, address), else: address
      :error -> last
    end
  end

  defp parse(hop) do
    hop = String.trim(hop)

    candidates =
      case Regex.run(~r/^\[([^\]]+)\](?::\d+)?$|^([^:]+):\d+$/, hop) do
        [_, v6] when v6 != "" -> [v6]
        [_, "", v4] -> [v4]
        _ -> [hop]
      end

    Enum.find_value(candidates, :error, fn text ->
      case :inet.parse_strict_address(String.to_charlist(text)) do
        {:ok, address} -> {:ok, address}
        _ -> nil
      end
    end)
  end

  @doc "Whether `address` (a tuple) is a proxy whose forwarded header is believed."
  @spec trusted?(:inet.ip_address()) :: boolean()
  def trusted?(address) do
    Enum.any?(trusted_proxies(), &Slipdock.Egress.in_cidr?(address, &1))
  end

  defp trusted_proxies, do: Slipdock.Config.get(:trusted_proxies, @default_trusted)

  defp format(address), do: address |> :inet.ntoa() |> to_string()
end
