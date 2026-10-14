defmodule Slipdock.CaddyFrontTest do
  @moduledoc """
  The optional Caddy front in deploy/caddy, which holds requests while the app
  restarts instead of answering them with 502s. These are the lines whose loss
  would not show until production: the deploy would look fine and either 502
  again or quietly put every visitor behind one address.
  """
  use ExUnit.Case, async: true

  alias SlipdockWeb.ClientIP

  @root Path.expand("../..", __DIR__)
  @caddyfile File.read!(Path.join(@root, "deploy/caddy/Caddyfile"))
  @override File.read!(Path.join(@root, "deploy/caddy/compose.override.yaml"))

  # Comments stripped, so a directive mentioned only in a comment does not count.
  defp directives(text),
    do: text |> String.split("\n") |> Enum.reject(&(String.trim(&1) |> String.starts_with?("#")))

  defp has?(text, line), do: Enum.any?(directives(text), &(String.trim(&1) == line))

  describe "the Caddyfile" do
    test "trusts the hop in front of it, or the visitor's address is replaced by the tunnel's" do
      assert has?(@caddyfile, "trusted_proxies static private_ranges")
    end

    test "retries the app while it is down rather than failing the request" do
      assert has?(@caddyfile, "reverse_proxy slipdock:4000 {")
      assert has?(@caddyfile, "lb_try_duration 30s")
      assert has?(@caddyfile, "lb_try_interval 250ms")
    end

    test "streams responses, for long-polls and MCP's server-sent events" do
      assert has?(@caddyfile, "flush_interval -1")
    end
  end

  describe "the compose override" do
    test "moves the published port from the app to Caddy" do
      assert has?(@override, "ports: !reset []")
      assert has?(@override, ~s(- "${SLIPDOCK_PUBLISH:-127.0.0.1:4000}:80"))
      assert has?(@override, "- ./Caddyfile:/etc/caddy/Caddyfile:ro")
    end

    test "does not make Caddy depend on the app, so recreating the app leaves Caddy running" do
      refute Enum.any?(directives(@override), &String.contains?(&1, "depends_on"))
    end

    test "is opt-in: nothing at the repo root for compose to pick up by itself" do
      refute File.exists?(Path.join(@root, "compose.override.yaml"))
      refute File.exists?(Path.join(@root, "Caddyfile"))
    end
  end

  test "the address chain Caddy passes on behind a tunnel resolves to the visitor" do
    # What the app saw in the rehearsal: the tunnel's X-Forwarded-For with
    # Caddy's peer (the docker gateway) appended, arriving from Caddy itself.
    resolved = ClientIP.resolve({172, 18, 0, 3}, ["198.51.100.7, 172.18.0.1"])
    assert resolved |> :inet.ntoa() |> to_string() == "198.51.100.7"

    # And a visitor who writes the header themselves still can't choose.
    resolved = ClientIP.resolve({172, 18, 0, 3}, ["1.2.3.4, 198.51.100.7, 172.18.0.1"])
    assert resolved |> :inet.ntoa() |> to_string() == "198.51.100.7"
  end
end
