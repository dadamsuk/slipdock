defmodule Slipdock.InboundTest do
  use ExUnit.Case, async: true

  alias Slipdock.{Inbound, TestConfig}

  test "off with nothing configured" do
    TestConfig.put(:inbound, [])

    refute Inbound.enabled?()
    assert Inbound.domain() == nil
    assert Inbound.secrets() == []
  end

  test "on with a domain and a secret" do
    TestConfig.put(:inbound, domain: "in.example.com", secrets: ["s3cret"])

    assert Inbound.enabled?()
    assert Inbound.domain() == "in.example.com"
    assert Inbound.secrets() == ["s3cret"]
  end

  test "a domain without a secret, or a secret without a domain, is off" do
    TestConfig.put(:inbound, domain: "in.example.com", secrets: [])
    refute Inbound.enabled?()

    TestConfig.put(:inbound, domain: nil, secrets: ["s3cret"])
    refute Inbound.enabled?()
  end

  test "blank values count as unset" do
    TestConfig.put(:inbound, domain: "  ", secrets: ["", " "])

    refute Inbound.enabled?()
    assert Inbound.domain() == nil
    assert Inbound.secrets() == []
  end

  test "the current and previous secrets are both accepted, current first" do
    TestConfig.put(:inbound, domain: "in.example.com", secrets: ["new", "old"])
    assert Inbound.secrets() == ["new", "old"]
  end

  describe "config/runtime.exs" do
    defp inbound_config(env) do
      script = ~S"""
      config = Config.Reader.read!("config/runtime.exs", env: :dev)
      IO.puts("INBOUND " <> inspect(config[:slipdock][:inbound]))
      """

      assigns = Enum.map(env, fn {name, value} -> "#{name}=#{value}" end)

      {out, 0} =
        System.cmd("env", assigns ++ [System.find_executable("elixir"), "-e", script],
          stderr_to_stdout: true
        )

      [_, inbound] = Regex.run(~r/^INBOUND (.*)$/m, out)
      {value, _} = Code.eval_string(inbound)
      value
    end

    test "reads the domain and both secrets" do
      assert inbound_config([
               {"SLIPDOCK_INBOUND_DOMAIN", "in.example.com"},
               {"SLIPDOCK_INBOUND_SECRET", "new"},
               {"SLIPDOCK_INBOUND_SECRET_PREVIOUS", "old"}
             ]) == [domain: "in.example.com", secrets: ["new", "old"]]
    end

    test "blank variables are left out" do
      assert inbound_config([
               {"SLIPDOCK_INBOUND_DOMAIN", " "},
               {"SLIPDOCK_INBOUND_SECRET", ""},
               {"SLIPDOCK_INBOUND_SECRET_PREVIOUS", ""}
             ]) == [domain: nil, secrets: []]
    end
  end
end
