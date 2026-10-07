defmodule SlipdockWeb.OriginTest do
  @moduledoc """
  Which origins may open a live-update socket.

  The failure this guards against is quiet: the page loads, the socket is
  refused, LiveView retries forever, and nothing in the browser says why. So
  these are as much about the message as the boolean.
  """
  # Sync: Origin remembers which hosts it has complained about in
  # :persistent_term, shared by every test, and these assert on that log line.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias SlipdockWeb.Origin

  defp hosts(list) do
    previous = Application.get_env(:slipdock, :origin_hosts)
    Application.put_env(:slipdock, :origin_hosts, list)
    :persistent_term.erase({Origin, :complained})

    on_exit(fn ->
      # Deleting, not putting nil back: a key present and nil is not an absent
      # key, and putting one back is what broke every other test in the suite.
      if previous,
        do: Application.put_env(:slipdock, :origin_hosts, previous),
        else: Application.delete_env(:slipdock, :origin_hosts)

      :persistent_term.erase({Origin, :complained})
    end)
  end

  defp origin(string), do: URI.parse(string)

  describe "allowed?/1" do
    test "the configured host is allowed" do
      hosts(["ps-prod-1"])
      assert Origin.allowed?(origin("http://ps-prod-1:4000"))
    end

    test "the port and scheme are not compared, as with Phoenix's own check" do
      # Insisting on them turns every reverse proxy into a support question,
      # and `check_origin: true` does not insist either.
      hosts(["slipdock.example.com"])

      assert Origin.allowed?(origin("https://slipdock.example.com"))
      assert Origin.allowed?(origin("http://slipdock.example.com:4000"))
      assert Origin.allowed?(origin("https://slipdock.example.com:8443"))
    end

    test "a different host is refused" do
      hosts(["slipdock.example.com"])
      refute capture_log(fn -> refute Origin.allowed?(origin("http://evil.example")) end) == ""
    end

    test "hostnames are compared without regard to case" do
      hosts(["PS-Prod-1"])
      assert Origin.allowed?(origin("http://ps-prod-1:4000"))
    end

    test "extra names are allowed alongside the main one" do
      # 203.0.113.0/24 is TEST-NET-3, reserved for documentation — a real
      # private-range address here is what `NothingPersonalTest` exists to stop.
      hosts(["slipdock.example.com", "ps-prod-1", "203.0.113.7"])

      assert Origin.allowed?(origin("http://ps-prod-1:4000"))
      assert Origin.allowed?(origin("http://203.0.113.7:4000"))
      assert Origin.allowed?(origin("https://slipdock.example.com"))
    end

    test "a wildcard covers subdomains, as it does everywhere else" do
      hosts(["*.example.com"])

      assert Origin.allowed?(origin("https://a.example.com"))
      assert Origin.allowed?(origin("https://b.a.example.com"))
      refute Origin.allowed?(origin("https://example.net"))
    end

    test "a wildcard needs a dot before its suffix" do
      hosts(["*.example.com"])

      refute Origin.allowed?(origin("https://evilexample.com"))
      refute Origin.allowed?(origin("https://a.evilexample.com"))
      assert Origin.allowed?(origin("https://A.Example.COM"))
    end

    test "an origin with no host at all is refused" do
      hosts(["slipdock.example.com"])
      refute Origin.allowed?(origin("null"))
      refute Origin.allowed?(%URI{})
    end
  end

  describe "the refusal message" do
    test "names the variable to set and the value to set it to" do
      hosts(["localhost"])

      log = capture_log(fn -> Origin.allowed?(origin("http://ps-prod-1:4000")) end)

      assert log =~ "PHX_HOST=ps-prod-1"
      assert log =~ "load and then never update"
      assert log =~ "SLIPDOCK_CHECK_ORIGIN"
    end

    test "is logged once per host, not once per retry" do
      hosts(["localhost"])

      first = capture_log(fn -> Origin.allowed?(origin("http://ps-prod-1:4000")) end)
      again = capture_log(fn -> Origin.allowed?(origin("http://ps-prod-1:4000")) end)

      # A refused socket reconnects in a loop, which would otherwise bury the
      # one line worth reading under copies of itself.
      assert first =~ "PHX_HOST"
      assert again == ""
    end

    test "stops remembering eventually, so forged origins cannot grow it" do
      hosts(["localhost"])

      for n <- 1..25, do: Origin.allowed?(origin("http://host-#{n}.example"))

      log = capture_log(fn -> Origin.allowed?(origin("http://host-99.example")) end)
      assert log == ""
    end
  end

  describe "the plug" do
    test "warns once when a page is served to an unexpected name" do
      hosts(["slipdock.example.com"])

      log =
        capture_log(fn ->
          SlipdockWeb.Origin.call(%Plug.Conn{host: "ps-prod-1"}, [])
        end)

      # The socket check only fires when LiveView connects, which is already
      # one symptom deep. This fires on the first page load.
      assert log =~ "PHX_HOST=ps-prod-1"
      assert log =~ "Not `restart`"

      again = capture_log(fn -> SlipdockWeb.Origin.call(%Plug.Conn{host: "ps-prod-1"}, []) end)
      assert again == ""
    end

    test "never refuses — it warns and carries on" do
      hosts(["slipdock.example.com"])
      conn = %Plug.Conn{host: "ps-prod-1"}

      assert capture_log(fn -> assert SlipdockWeb.Origin.call(conn, []) == conn end) =~ "PHX_HOST"
    end

    test "says nothing about loopback, which is how health checks arrive" do
      # The container's own HEALTHCHECK curls 127.0.0.1; a warning for that
      # would be a false alarm on every single server.
      hosts(["slipdock.example.com"])

      for host <- ["localhost", "127.0.0.1", "::1", "0.0.0.0"] do
        assert capture_log(fn -> SlipdockWeb.Origin.call(%Plug.Conn{host: host}, []) end) == ""
      end
    end

    test "says nothing when the name is right" do
      hosts(["slipdock.example.com"])

      assert capture_log(fn ->
               SlipdockWeb.Origin.call(%Plug.Conn{host: "slipdock.example.com"}, [])
             end) == ""
    end

    test "is inert where it is not configured, which is dev and test" do
      hosts([])

      assert capture_log(fn -> SlipdockWeb.Origin.call(%Plug.Conn{host: "anything"}, []) end) ==
               ""
    end
  end

  describe "parse/1" do
    test "accepts every shape people actually write" do
      # Phoenix's own docs show all of these, so all of them turn up.
      assert Origin.parse("example.com") == ["example.com"]
      assert Origin.parse("//example.com") == ["example.com"]
      assert Origin.parse("https://example.com") == ["example.com"]
      assert Origin.parse("https://example.com:8443") == ["example.com"]
    end

    test "splits a list and ignores the gaps" do
      assert Origin.parse("a.example, //b.example , ,https://c.example") ==
               ["a.example", "b.example", "c.example"]
    end

    test "nothing is nothing" do
      assert Origin.parse(nil) == []
      assert Origin.parse("") == []
      assert Origin.parse("  ,  ") == []
    end
  end
end
