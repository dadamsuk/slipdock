defmodule Slipdock.PublishedPortTrustTest do
  @moduledoc """
  compose.yaml's `SLIPDOCK_TRUSTED_PROXIES=local` trusts the compose network,
  gateway included. A visitor through the published port keeps their own
  address only where Docker forwards the port in the kernel; under rootless
  Docker, Docker Desktop, or for an IPv6 visitor to the IPv4-only network, a
  userland forwarder carries the connection and it arrives from the gateway
  (#2967, checked on rootless Docker 28.5: a client on another machine's
  address reached the container as 172.18.0.1).

  The default stays, since a host proxy arrives from that same gateway and
  can't be told apart. So the file and the docs have to say when it holds and
  what to set where it doesn't, and these tests keep them saying it.
  """
  use ExUnit.Case, async: true

  import Slipdock.DocsFacts, only: [assert_states: 2]

  alias SlipdockWeb.ClientIP

  @root Path.expand("../..", __DIR__)

  defp read(rel), do: @root |> Path.join(rel) |> File.read!()

  # One line of text, so a phrase wrapped across lines (or comment markers) still matches.
  defp flat(text),
    do: text |> String.replace(~r/\s*\n\s*#?\s*/, " ") |> String.replace(~r/\s+/, " ")

  defp resolve(peer, forwarded),
    do: peer |> ClientIP.resolve(forwarded) |> :inet.ntoa() |> to_string()

  describe "what the gateway is believed about" do
    test "under the compose network's trust, a forwarded visitor picks their own address" do
      # What "local" resolves to inside the container, in the rootless check.
      Slipdock.TestConfig.put(:trusted_proxies, ["127.0.0.0/8", "172.18.0.0/16"])

      # A visitor a userland forwarder carried in: the peer is the gateway,
      # and the header is whatever they wrote.
      assert resolve({172, 18, 0, 1}, ["203.0.113.9"]) == "203.0.113.9"

      # Where the kernel forwards the port, the peer is the visitor, who is not believed.
      assert resolve({198, 51, 100, 7}, ["203.0.113.9"]) == "198.51.100.7"
    end

    test "naming the proxy alone, or nobody, stops it" do
      # The proxy's own address, as the docs advise in place of "local".
      Slipdock.TestConfig.put(:trusted_proxies, ["172.18.0.3/32"])
      assert resolve({172, 18, 0, 1}, ["203.0.113.9"]) == "172.18.0.1"
      assert resolve({172, 18, 0, 3}, ["198.51.100.7"]) == "198.51.100.7"

      # SLIPDOCK_TRUSTED_PROXIES=none.
      Slipdock.TestConfig.put(:trusted_proxies, [])
      assert resolve({172, 18, 0, 1}, ["203.0.113.9"]) == "172.18.0.1"
    end
  end

  describe "compose.yaml" do
    setup do
      %{compose: read("compose.yaml")}
    end

    test "still defaults to local, on a loopback publish", %{compose: compose} do
      assert compose =~ "- SLIPDOCK_TRUSTED_PROXIES=${SLIPDOCK_TRUSTED_PROXIES:-local}"
      assert compose =~ ~s("${SLIPDOCK_PUBLISH:-127.0.0.1:4000}:4000")
    end

    test "says when a visitor keeps their own address, and when not", %{compose: compose} do
      text = flat(compose)

      assert_states(text, "only where Docker forwards the port in the kernel")

      for setup <- ["rootless Docker", "Docker Desktop", "IPv6 visitor", "IPv4-only"] do
        assert text =~ setup, "compose.yaml no longer names #{setup}"
      end

      assert_states(
        text,
        "With SLIPDOCK_PUBLISH=4000 on one of those, anybody who reaches the port could write their own X-Forwarded-For"
      )

      assert_states(
        text,
        ~s(set SLIPDOCK_TRUSTED_PROXIES to the proxy's own address, or "none" with no proxy)
      )

      refute text =~ "On Linux Docker a visitor"
    end
  end

  describe "the docs" do
    test "the manual's Docker page names the setups and the three ways out" do
      text = flat(read("docs/manual/docker-step-by-step.md"))

      for setup <- ["**rootless Docker**", "**Docker Desktop**", "**IPv6 visitor**"] do
        assert text =~ setup, "the Docker page no longer names #{setup}"
      end

      assert_states(
        text,
        "every visitor arrives from the network's gateway, which `local` trusts"
      )

      assert text =~ "which `local` trusts"
      assert_states(text, "keep the port on loopback and put the proxy in front")
      assert_states(text, "with no proxy at all, set `SLIPDOCK_TRUSTED_PROXIES=none`")

      assert_states(
        text,
        "name its address alone (`SLIPDOCK_TRUSTED_PROXIES=172.18.0.3/32`) instead of `local`"
      )
    end

    test "the rate-limit page points there, to a heading that exists" do
      assert_states(
        flat(read("docs/manual/accounts-and-sharing.md")),
        "Under rootless Docker or Docker Desktop, `local` is too wide for a port published to other machines: see docker-step-by-step.md#behind-a-tls-proxy"
      )

      assert read("docs/manual/accounts-and-sharing.md") =~
               "(docker-step-by-step.md#behind-a-tls-proxy)"

      assert read("docs/manual/docker-step-by-step.md") =~ "\n### Behind a TLS proxy\n"
    end

    test ".env.example warns at both variables" do
      text = flat(read(".env.example"))

      assert text =~ "read SLIPDOCK_TRUSTED_PROXIES below"

      assert_states(
        text,
        "Before publishing to other machines under rootless Docker or Docker Desktop, read SLIPDOCK_TRUSTED_PROXIES below"
      )

      assert_states(
        text,
        ~s(with SLIPDOCK_PUBLISH=4000 there, use "none" or the proxy's own address, not "local")
      )
    end

    test "ClientIP's moduledoc no longer says it without the condition" do
      {:docs_v1, _, _, _, %{"en" => doc}, _, _} = Code.fetch_docs(ClientIP)
      text = flat(doc)

      for setup <- ["rootless Docker", "Docker Desktop", "IPv6 visitor"] do
        assert text =~ setup, "the moduledoc no longer names #{setup}"
      end

      assert_states(text, "holds only where Docker forwards the port in the kernel")

      assert_states(
        text,
        "Under rootless Docker, Docker Desktop, or for an IPv6 visitor to an IPv4-only compose network"
      )
    end
  end
end
