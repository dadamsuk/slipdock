defmodule Slipdock.Egress do
  @moduledoc """
  The one gate every request to a URL somebody typed goes through: webhook
  callbacks and a person's own AI endpoint.

  Without it, a URL is a way to make the server knock on its own doors —
  `127.0.0.1`, the cloud metadata service at `169.254.169.254`, the LAN, the
  tailnet — and read back whatever answered. So `prepare/1`:

    * takes only `http`/`https` URLs with a host;
    * resolves the host and refuses it if **any** address it resolves to is
      loopback, private, link-local, CGNAT (which is also where Tailscale
      lives), multicast, reserved, or IPv6 that wraps one of those
      (`::ffff:a.b.c.d`, NAT64);
    * pins the request to the address it checked, so a second DNS answer
      cannot swap in a different one, and turns redirects off, so a public
      host cannot bounce the request inward.

  A model server on the LAN is a real use, so the server's admin can open
  ranges back up: `config :slipdock, :egress, allow: ["<network>/<bits>"]`, or
  `allow: :all` to switch the check off — `SLIPDOCK_EGRESS_ALLOW` sets either
  (`all`, or a comma-separated list of CIDRs and addresses).
  """

  import Bitwise

  @blocked_v4 [
    {{0, 0, 0, 0}, 8},
    {{10, 0, 0, 0}, 8},
    {{100, 64, 0, 0}, 10},
    {{127, 0, 0, 0}, 8},
    {{169, 254, 0, 0}, 16},
    {{172, 16, 0, 0}, 12},
    {{192, 0, 0, 0}, 24},
    {{192, 0, 2, 0}, 24},
    {{192, 168, 0, 0}, 16},
    {{198, 18, 0, 0}, 15},
    {{198, 51, 100, 0}, 24},
    {{203, 0, 113, 0}, 24},
    {{224, 0, 0, 0}, 4},
    {{240, 0, 0, 0}, 4}
  ]

  @blocked_v6 [
    # Unspecified, loopback and the IPv4-compatible/mapped forms.
    {{0, 0, 0, 0, 0, 0, 0, 0}, 96},
    {{0, 0, 0, 0, 0, 0xFFFF, 0, 0}, 96},
    {{0x64, 0xFF9B, 0, 0, 0, 0, 0, 0}, 96},
    {{0x64, 0xFF9B, 1, 0, 0, 0, 0, 0}, 48},
    {{0x100, 0, 0, 0, 0, 0, 0, 0}, 64},
    {{0x2001, 0xDB8, 0, 0, 0, 0, 0, 0}, 32},
    {{0xFC00, 0, 0, 0, 0, 0, 0, 0}, 7},
    {{0xFE80, 0, 0, 0, 0, 0, 0, 0}, 10},
    {{0xFF00, 0, 0, 0, 0, 0, 0, 0}, 8}
  ]

  @typedoc "Why a URL was refused, in words fit to show the person who typed it."
  @type reason :: String.t()

  @doc """
  Checks `url` and returns `{:ok, url, req_options}` — the URL with its host
  replaced by the address that was checked, and the `Req` options that keep
  the original name for TLS and the `Host` header and turn redirects off — or
  `{:error, reason}`.
  """
  @spec prepare(String.t()) :: {:ok, String.t(), keyword()} | {:error, reason}
  def prepare(url) do
    with {:ok, uri} <- parse(url),
         {:ok, address} <- resolve(uri.host) do
      pinned = %URI{uri | host: format(address)}

      options =
        [redirect: false] ++
          if ip_literal?(uri.host), do: [], else: [connect_options: [hostname: uri.host]]

      {:ok, URI.to_string(pinned), options}
    end
  end

  @doc """
  The checks that need no DNS, for when a URL is saved: an http(s) URL with a
  host, and not an address literal (or `localhost`) that `prepare/1` would
  refuse anyway.
  """
  @spec check_static(String.t()) :: :ok | {:error, reason}
  def check_static(url) do
    with {:ok, uri} <- parse(url) do
      cond do
        localhost?(uri.host) ->
          if blocked?({127, 0, 0, 1}), do: {:error, blocked()}, else: :ok

        address = literal(uri.host) ->
          if blocked?(address), do: {:error, blocked()}, else: :ok

        true ->
          :ok
      end
    end
  end

  @doc "Whether this address is one `prepare/1` refuses, given the allow list."
  @spec blocked?(:inet.ip_address()) :: boolean()
  def blocked?(address), do: private?(address) and not allowed?(address)

  ## Parsing -----------------------------------------------------------------

  defp parse(url) when is_binary(url) do
    case URI.new(url) do
      {:ok, %URI{scheme: scheme, host: host} = uri}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        {:ok, uri}

      _ ->
        {:error, "is not an http(s) URL"}
    end
  end

  defp parse(_), do: {:error, "is not an http(s) URL"}

  defp blocked, do: "is not a public address"

  ## Resolving ---------------------------------------------------------------

  defp resolve(host) do
    addresses =
      cond do
        address = literal(host) -> [address]
        # RFC 6761: always loopback, whatever a resolver might say.
        localhost?(host) -> [{127, 0, 0, 1}]
        true -> lookup(host)
      end

    cond do
      addresses == [] -> {:error, "could not be resolved"}
      Enum.any?(addresses, &blocked?/1) -> {:error, blocked()}
      true -> {:ok, hd(addresses)}
    end
  end

  # URI keeps an IPv6 literal's brackets off `host`.
  defp literal(host) do
    case :inet.parse_strict_address(String.to_charlist(host)) do
      {:ok, address} -> address
      _ -> nil
    end
  end

  defp ip_literal?(host), do: literal(host) != nil

  defp localhost?(host) do
    host = host |> String.trim_trailing(".") |> String.downcase()
    host == "localhost" or String.ends_with?(host, ".localhost")
  end

  defp lookup(host) do
    case config()[:resolver] do
      fun when is_function(fun, 1) ->
        fun.(host)

      nil ->
        name = String.to_charlist(host)

        for family <- [:inet, :inet6],
            {:ok, found} <- [:inet.getaddrs(name, family)],
            address <- found,
            do: address
    end
  end

  # Bare, even for IPv6: `URI.to_string/1` puts the brackets back.
  defp format(address), do: address |> :inet.ntoa() |> to_string()

  ## Ranges ------------------------------------------------------------------

  defp private?({_, _, _, _} = address), do: Enum.any?(@blocked_v4, &in_range?(address, &1))
  defp private?(address), do: Enum.any?(@blocked_v6, &in_range?(address, &1))

  defp allowed?(address) do
    case config()[:allow] do
      :all -> true
      list when is_list(list) -> Enum.any?(list, &allows?(&1, address))
      _ -> false
    end
  end

  defp allows?(entry, address) do
    case cidr(entry) do
      {network, bits} when tuple_size(network) == tuple_size(address) ->
        in_range?(address, {network, bits})

      _ ->
        false
    end
  end

  @doc false
  # "a.b.c.d/n", "fd00::/8" or a bare address, as `{address, prefix}`.
  def cidr(entry) when is_binary(entry) do
    {address, bits} =
      case String.split(String.trim(entry), "/", parts: 2) do
        [address, bits] -> {address, Integer.parse(bits)}
        [address] -> {address, :whole}
      end

    with {:ok, network} <- :inet.parse_strict_address(String.to_charlist(address)) do
      width = if tuple_size(network) == 4, do: 32, else: 128

      case bits do
        :whole -> {network, width}
        {n, ""} when n >= 0 and n <= width -> {network, n}
        _ -> nil
      end
    else
      _ -> nil
    end
  end

  def cidr(_), do: nil

  defp in_range?(address, {network, bits}) do
    width = if tuple_size(address) == 4, do: 32, else: 128

    tuple_size(address) == tuple_size(network) and
      to_integer(address) >>> (width - bits) == to_integer(network) >>> (width - bits)
  end

  defp to_integer({_, _, _, _} = address), do: pack(Tuple.to_list(address), 8)
  defp to_integer(address), do: pack(Tuple.to_list(address), 16)

  defp pack(parts, size), do: Enum.reduce(parts, 0, &(&2 <<< size ||| &1))

  defp config, do: Application.get_env(:slipdock, :egress, [])
end
