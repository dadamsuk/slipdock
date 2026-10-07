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
    assert resolve({172, 18, 0, 2}, ["198.51.100.7"]) == "198.51.100.7"
  end

  test "it reads from the right, so a client cannot prepend an address of its choosing" do
    # The client sent "1.2.3.4"; the proxy appended the address it really saw.
    assert resolve({127, 0, 0, 1}, ["1.2.3.4, 198.51.100.7"]) == "198.51.100.7"
    # Two proxies of ours in a row are both skipped.
    assert resolve({127, 0, 0, 1}, ["1.2.3.4, 198.51.100.7, 172.16.0.5"]) == "198.51.100.7"
    # Repeated headers are one list.
    assert resolve({127, 0, 0, 1}, ["1.2.3.4", "198.51.100.7"]) == "198.51.100.7"
  end

  test "garbage stops the walk at the last address a trusted proxy vouched for" do
    assert resolve({127, 0, 0, 1}, ["nonsense"]) == "127.0.0.1"
    assert resolve({127, 0, 0, 1}, ["198.51.100.7, unknown, 172.16.0.5"]) == "172.16.0.5"
  end

  test "ports and bracketed IPv6 are understood" do
    assert resolve({127, 0, 0, 1}, ["198.51.100.7:4711"]) == "198.51.100.7"
    assert resolve({127, 0, 0, 1}, ["[2001:db8::1]:443"]) == "2001:db8::1"
    assert resolve({0, 0, 0, 0, 0, 0, 0, 1}, ["2001:db8::1"]) == "2001:db8::1"
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
end
