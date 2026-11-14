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
  (`SLIPDOCK_TRUSTED_PROXIES` in the environment). The default is loopback
  only, which covers a proxy on the same host. It used to be every private
  range as well, which let anybody on the same LAN as a directly exposed
  server pick their own address (#2796).

  An entry `"local"` stands for loopback and the networks this machine's own
  interfaces are on. That is what `compose.yaml` sets: inside a container
  those are the compose network, so Caddy or a proxy on the host (which
  reaches a published port from the network's gateway) is believed, while a
  visitor arriving through the published port keeps their own address. That
  last part holds only where Docker forwards the port in the kernel (rootful
  Linux Docker, an IPv4 visitor). Under rootless Docker, Docker Desktop, or for
  an IPv6 visitor to an IPv4-only compose network, a userland forwarder
  carries the connection and the visitor arrives from the gateway as well, so
  a port published beyond loopback there needs the proxy named, or `none`
  (#2967; `compose.yaml` and the manual's Docker page say so). On a host with
  its own LAN interface `"local"` would trust the whole LAN, so it is for
  containers.
  """

  @default_trusted ~w(127.0.0.0/8 ::1/128)

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
  The client address of a plain `Phoenix.Socket` connection, from the
  `connect_info` it was given (`:peer_data` and `:x_headers`); nil when
  there is none to read.
  """
  def from_connect_info(%{peer_data: %{address: address}} = info) do
    forwarded = for {"x-forwarded-for", value} <- Map.get(info, :x_headers) || [], do: value
    address |> resolve(forwarded) |> format()
  end

  def from_connect_info(_info), do: nil

  @doc """
  The client address given the peer (a tuple) and every `X-Forwarded-For`
  value the request carried, in order.
  """
  @spec resolve(:inet.ip_address(), [String.t()]) :: :inet.ip_address()
  def resolve(peer, forwarded) do
    peer = unmap(peer)

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
        {:ok, address} -> {:ok, unmap(address)}
        _ -> nil
      end
    end)
  end

  # A dual-stack listener reports an IPv4 peer as ::ffff:a.b.c.d, which is
  # how the app in Docker sees the proxy in front of it. Judged as IPv6 it
  # matches none of the IPv4 ranges, so the proxy went untrusted and every
  # visitor was counted as the proxy.
  defp unmap({0, 0, 0, 0, 0, 0xFFFF, high, low}),
    do:
      {Bitwise.bsr(high, 8), Bitwise.band(high, 0xFF), Bitwise.bsr(low, 8),
       Bitwise.band(low, 0xFF)}

  defp unmap(address), do: address

  @doc "Whether `address` (a tuple) is a proxy whose forwarded header is believed."
  @spec trusted?(:inet.ip_address()) :: boolean()
  def trusted?(address) do
    Enum.any?(trusted_proxies(), &Slipdock.Egress.in_cidr?(address, &1))
  end

  defp trusted_proxies do
    :trusted_proxies
    |> Slipdock.Config.get(@default_trusted)
    |> Enum.flat_map(fn
      "local" -> @default_trusted ++ local_networks()
      cidr -> [cidr]
    end)
  end

  # Read once: a container's interfaces are set before the app starts.
  defp local_networks do
    case :persistent_term.get({__MODULE__, :local_networks}, nil) do
      nil ->
        {:ok, ifaddrs} = :inet.getifaddrs()
        networks = networks(ifaddrs)
        :persistent_term.put({__MODULE__, :local_networks}, networks)
        networks

      networks ->
        networks
    end
  end

  @doc """
  The networks of the interfaces in `:inet.getifaddrs/0`'s answer, as CIDRs:
  each address with the prefix its netmask gives.
  """
  @spec networks([{charlist() | String.t(), keyword()}]) :: [String.t()]
  def networks(ifaddrs) do
    Enum.flat_map(ifaddrs, fn {_name, opts} -> pairs(opts, nil) end)
  end

  # An interface lists each address followed by its netmask.
  defp pairs([], _address), do: []

  defp pairs([{:addr, address} | rest], _), do: pairs(rest, address)

  defp pairs([{:netmask, mask} | rest], address)
       when is_tuple(address) and tuple_size(mask) == tuple_size(address),
       do: [cidr(address, mask) | pairs(rest, nil)]

  defp pairs([_ | rest], address), do: pairs(rest, address)

  defp cidr(address, mask) do
    size = if tuple_size(mask) == 4, do: 8, else: 16

    bits =
      mask
      |> Tuple.to_list()
      |> Enum.map(&(<<&1::size(size)>> |> ones()))
      |> Enum.sum()

    "#{:inet.ntoa(address)}/#{bits}"
  end

  defp ones(bits), do: for(<<bit::1 <- bits>>, reduce: 0, do: (n -> n + bit))

  defp format(address), do: address |> :inet.ntoa() |> to_string()
end
