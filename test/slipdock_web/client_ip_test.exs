defmodule SlipdockWeb.ClientIPTest do
  @moduledoc """
  Which address a request is counted against. X-Forwarded-For is anybody's to
  write, so it only counts when a proxy we trust passed it on.
  """
  use ExUnit.Case, async: true

  alias Slipdock.TestConfig
  alias SlipdockWeb.ClientIP

  defp resolve(peer, forwarded),
    do: peer |> ClientIP.resolve(forwarded) |> :inet.ntoa() |> to_string()

  test "a forwarded header from an untrusted peer is ignored" do
    assert resolve({203, 0, 113, 9}, ["1.2.3.4"]) == "203.0.113.9"
  end

  test "behind a trusted proxy, the visitor's address is used" do
    assert resolve({127, 0, 0, 1}, ["198.51.100.7"]) == "198.51.100.7"
    assert resolve({0, 0, 0, 0, 0, 0, 0, 1}, ["198.51.100.7"]) == "198.51.100.7"
  end

  # #2796: the default was every private range, so on a LAN anybody could
  # write their own header and dodge the per-IP limits.
  test "by default a spoofed header from a private address is ignored" do
    for peer <- [{192, 168, 1, 50}, {10, 0, 0, 7}, {172, 16, 0, 5}, {0xFD00, 0, 0, 0, 0, 0, 0, 9}] do
      assert resolve(peer, ["1.2.3.4"]) == peer |> :inet.ntoa() |> to_string()
    end

    conn =
      Plug.Test.conn(:get, "/")
      |> Map.put(:remote_ip, {192, 168, 1, 50})
      |> Plug.Conn.put_req_header("x-forwarded-for", "1.2.3.4")

    assert ClientIP.from_conn(conn) == "192.168.1.50"
    refute ClientIP.trusted?({172, 18, 0, 2})
  end

  test "behind a trusted proxy, a private hop it appends is not skipped by default" do
    # The private hop is somebody else's now, so it is the client.
    assert resolve({127, 0, 0, 1}, ["198.51.100.7, 192.168.1.50"]) == "192.168.1.50"
  end

  test "it reads from the right, so a client cannot prepend an address of its choosing" do
    TestConfig.put(:trusted_proxies, ["127.0.0.0/8", "172.16.0.0/12"])
    # The client sent "1.2.3.4"; the proxy appended the address it really saw.
    assert resolve({127, 0, 0, 1}, ["1.2.3.4, 198.51.100.7"]) == "198.51.100.7"
    # Two proxies of ours in a row are both skipped.
    assert resolve({127, 0, 0, 1}, ["1.2.3.4, 198.51.100.7, 172.16.0.5"]) == "198.51.100.7"
    # Repeated headers are one list.
    assert resolve({127, 0, 0, 1}, ["1.2.3.4", "198.51.100.7"]) == "198.51.100.7"
  end

  test "garbage stops the walk at the last address a trusted proxy vouched for" do
    TestConfig.put(:trusted_proxies, ["127.0.0.0/8", "172.16.0.0/12"])
    assert resolve({127, 0, 0, 1}, ["nonsense"]) == "127.0.0.1"
    assert resolve({127, 0, 0, 1}, ["198.51.100.7, unknown, 172.16.0.5"]) == "172.16.0.5"
  end

  test "ports and bracketed IPv6 are understood" do
    assert resolve({127, 0, 0, 1}, ["198.51.100.7:4711"]) == "198.51.100.7"
    assert resolve({127, 0, 0, 1}, ["[2001:db8::1]:443"]) == "2001:db8::1"
    assert resolve({0, 0, 0, 0, 0, 0, 0, 1}, ["2001:db8::1"]) == "2001:db8::1"
  end

  # A dual-stack listener sees an IPv4 peer as ::ffff:a.b.c.d. That is how the
  # app in Docker sees the proxy in front of it, so a mapped address must be
  # judged as the IPv4 address it carries.
  test "an IPv4-mapped IPv6 peer is trusted as its IPv4 address" do
    TestConfig.put(:trusted_proxies, ["127.0.0.0/8", "172.18.0.0/16"])
    caddy = {0, 0, 0, 0, 0, 0xFFFF, 0xAC12, 0x0003}

    assert resolve(caddy, ["198.51.100.7, 172.18.0.1"]) == "198.51.100.7"
    assert resolve({0, 0, 0, 0, 0, 0xFFFF, 0x7F00, 0x0001}, ["198.51.100.7"]) == "198.51.100.7"
  end

  test "a mapped address that is not trusted still is not, and comes out as IPv4" do
    stranger = {0, 0, 0, 0, 0, 0xFFFF, 0xCB00, 0x7109}

    assert resolve(stranger, ["1.2.3.4"]) == "203.0.113.9"
  end

  test "mapped hops in the header are walked like IPv4 ones" do
    TestConfig.put(:trusted_proxies, ["127.0.0.0/8", "172.18.0.0/16"])
    assert resolve({127, 0, 0, 1}, ["198.51.100.7, ::ffff:172.18.0.1"]) == "198.51.100.7"
    assert resolve({127, 0, 0, 1}, ["::ffff:198.51.100.7"]) == "198.51.100.7"
    assert resolve({127, 0, 0, 1}, ["[::ffff:198.51.100.7]:443"]) == "198.51.100.7"
  end

  test "the trusted list is configurable, and can be empty" do
    TestConfig.put(:trusted_proxies, [])
    assert resolve({127, 0, 0, 1}, ["198.51.100.7"]) == "127.0.0.1"

    TestConfig.put(:trusted_proxies, ["203.0.113.0/24"])
    assert resolve({203, 0, 113, 9}, ["198.51.100.7"]) == "198.51.100.7"
    assert resolve({127, 0, 0, 1}, ["198.51.100.7"]) == "127.0.0.1"
  end

  test "from_conn reads the peer and the header" do
    conn =
      Plug.Test.conn(:get, "/")
      |> Map.put(:remote_ip, {203, 0, 113, 9})
      |> Plug.Conn.put_req_header("x-forwarded-for", "1.2.3.4")

    assert ClientIP.from_conn(conn) == "203.0.113.9"
    assert ClientIP.from_conn(%{conn | remote_ip: {127, 0, 0, 1}}) == "1.2.3.4"
  end

  test "from_conn behind Caddy on a dual-stack listener gives the visitor" do
    TestConfig.put(:trusted_proxies, ["127.0.0.0/8", "172.18.0.0/16"])

    conn =
      Plug.Test.conn(:get, "/")
      |> Map.put(:remote_ip, {0, 0, 0, 0, 0, 0xFFFF, 0xAC12, 0x0003})
      |> Plug.Conn.put_req_header("x-forwarded-for", "198.51.100.7, 172.18.0.1")

    assert ClientIP.from_conn(conn) == "198.51.100.7"
  end

  describe "local" do
    test "trusts loopback and the networks of this machine's own interfaces" do
      TestConfig.put(:trusted_proxies, ["local"])
      {:ok, ifaddrs} = :inet.getifaddrs()

      own =
        for {_name, opts} <- ifaddrs,
            {:addr, {a, b, c, d}} <- opts,
            a != 127,
            do: {a, b, c, d}

      assert resolve({127, 0, 0, 1}, ["198.51.100.7"]) == "198.51.100.7"
      assert resolve({0, 0, 0, 0, 0, 0, 0, 1}, ["198.51.100.7"]) == "198.51.100.7"
      for address <- own, do: assert(resolve(address, ["198.51.100.7"]) == "198.51.100.7")

      # An address on none of them is not believed.
      assert resolve({203, 0, 113, 9}, ["1.2.3.4"]) == "203.0.113.9"
    end

    test "combines with CIDRs of its own" do
      TestConfig.put(:trusted_proxies, ["local", "203.0.113.0/24"])

      assert resolve({203, 0, 113, 9}, ["198.51.100.7"]) == "198.51.100.7"
      assert resolve({127, 0, 0, 1}, ["198.51.100.7"]) == "198.51.100.7"
      assert resolve({198, 18, 0, 1}, ["1.2.3.4"]) == "198.18.0.1"
    end

    test "networks pairs each address with the netmask after it" do
      # The shape a container's :inet.getifaddrs/0 answers with.
      ifaddrs = [
        {~c"lo",
         [
           flags: [:up, :loopback, :running],
           addr: {127, 0, 0, 1},
           netmask: {255, 0, 0, 0},
           addr: {0, 0, 0, 0, 0, 0, 0, 1},
           netmask: {65_535, 65_535, 65_535, 65_535, 65_535, 65_535, 65_535, 65_535},
           hwaddr: [0, 0, 0, 0, 0, 0]
         ]},
        {~c"eth0",
         [
           flags: [:up, :broadcast, :running, :multicast],
           addr: {172, 18, 0, 3},
           netmask: {255, 255, 240, 0},
           broadaddr: {172, 18, 15, 255},
           addr: {0xFE80, 0, 0, 0, 0x42, 0xACFF, 0xFE12, 3},
           netmask: {65_535, 65_535, 65_535, 65_535, 0, 0, 0, 0},
           hwaddr: [2, 66, 172, 18, 0, 3]
         ]},
        # An address with no netmask is skipped, not guessed at.
        {~c"tun0", [flags: [:up], addr: {10, 8, 0, 1}]}
      ]

      assert ClientIP.networks(ifaddrs) == [
               "127.0.0.1/8",
               "::1/128",
               "172.18.0.3/20",
               "fe80::42:acff:fe12:3/64"
             ]
    end

    test "compose.yaml names its own network, and lets .env say otherwise" do
      compose = File.read!(Path.expand("../../compose.yaml", __DIR__))
      assert compose =~ "- SLIPDOCK_TRUSTED_PROXIES=${SLIPDOCK_TRUSTED_PROXIES:-local}"
    end
  end
end
