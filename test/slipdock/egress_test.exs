defmodule Slipdock.EgressTest do
  use ExUnit.Case, async: false

  alias Slipdock.Egress

  @public Slipdock.EgressStub.public() |> :inet.ntoa() |> to_string()

  describe "prepare/1" do
    test "pins a public name to the address it checked, keeping the name for TLS" do
      assert {:ok, url, options} = Egress.prepare("https://hooks.example.com:8443/a?b=1")
      assert url == "https://#{@public}:8443/a?b=1"
      assert options[:redirect] == false
      assert options[:connect_options] == [hostname: "hooks.example.com"]
    end

    test "refuses loopback, private, link-local, CGNAT and their IPv6 forms" do
      for url <- ~w(
            http://127.0.0.1/ http://127.1.2.3:8080/ http://0.0.0.0/
            http://10.1.1.1/ http://172.16.5.5/ http://192.168.1.1/
            http://169.254.169.254/latest/meta-data/ http://100.64.0.1/ http://100.127.255.254/
            http://224.0.0.1/ http://255.255.255.255/
            http://[::1]/ http://[::]/ http://[::ffff:127.0.0.1]/ http://[::ffff:a9fe:a9fe]/
            http://[fc00::1]/ http://[fd12:3456::1]/ http://[fe80::1]/ http://[64:ff9b::a00:1]/
          ) do
        assert {:error, "is not a public address"} = Egress.prepare(url), url
      end
    end

    test "refuses a name if any address it resolves to is private" do
      for host <- ~w(intranet.test tailnet.test metadata.test split.test) do
        assert {:error, "is not a public address"} = Egress.prepare("http://#{host}/"), host
      end
    end

    test "refuses what isn't an http(s) URL, or doesn't resolve" do
      assert {:error, "is not an http(s) URL"} = Egress.prepare("file:///etc/passwd")
      assert {:error, "is not an http(s) URL"} = Egress.prepare("gopher://example.com/")
      assert {:error, "is not an http(s) URL"} = Egress.prepare("http:///nohost")
      assert {:error, "could not be resolved"} = Egress.prepare("http://nowhere.test/")
    end

    test "a public IP literal needs no hostname" do
      assert {:ok, "http://93.184.216.34/x", options} = Egress.prepare("http://93.184.216.34/x")
      refute options[:connect_options]
    end

    test "an IPv6 public literal keeps its brackets" do
      assert {:ok, "http://[2606:4700::1111]/x", _} = Egress.prepare("http://[2606:4700::1111]/x")
    end
  end

  describe "the allow list" do
    setup do
      previous = Application.get_env(:slipdock, :egress)
      on_exit(fn -> Application.put_env(:slipdock, :egress, previous) end)
      %{previous: previous}
    end

    test "reopens just the ranges named", %{previous: previous} do
      Application.put_env(:slipdock, :egress, Keyword.put(previous, :allow, ["100.64.0.0/10"]))

      assert {:ok, _, _} = Egress.prepare("http://tailnet.test:1234/v1")
      assert {:error, _} = Egress.prepare("http://intranet.test/")
      assert {:error, _} = Egress.prepare("http://127.0.0.1/")
    end

    test ":all switches the check off", %{previous: previous} do
      Application.put_env(:slipdock, :egress, Keyword.put(previous, :allow, :all))

      assert {:ok, _, _} = Egress.prepare("http://127.0.0.1:4000/")
      assert :ok = Egress.check_static("http://localhost/")
    end

    test "parses CIDRs and bare addresses, and ignores nonsense" do
      assert Egress.cidr("10.0.0.0/8") == {{10, 0, 0, 0}, 8}
      assert Egress.cidr("fd00::/8") == {{0xFD00, 0, 0, 0, 0, 0, 0, 0}, 8}
      assert Egress.cidr("192.0.2.7") == {{192, 0, 2, 7}, 32}
      assert Egress.cidr("10.0.0.0/33") == nil
      assert Egress.cidr("llm.local") == nil
    end
  end

  describe "check_static/1" do
    test "refuses literals and localhost without asking DNS" do
      assert {:error, _} = Egress.check_static("http://127.0.0.1/")
      assert {:error, _} = Egress.check_static("http://localhost:8080/")
      assert {:error, _} = Egress.check_static("http://api.localhost/")
      assert :ok = Egress.check_static("https://intranet.test/")
      assert :ok = Egress.check_static("https://example.com/hook")
    end
  end
end
