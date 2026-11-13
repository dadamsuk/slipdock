defmodule Slipdock.RuntimeListVarsTest do
  # The two list-valued security settings as config/runtime.exs reads them
  # (#2084): SLIPDOCK_EGRESS_ALLOW (which private addresses webhooks and AI
  # endpoints may reach, `Slipdock.Egress`) and SLIPDOCK_TRUSTED_PROXIES (whose
  # X-Forwarded-For is believed, `SlipdockWeb.ClientIP`). Each takes a keyword
  # or a comma-separated list of CIDRs. Read as prod reads it, in a separate
  # `elixir`, so the variables set here stay out of this VM.
  use ExUnit.Case, async: true

  @base [
    {"DATABASE_URL", "ecto://db.example.com/slipdock"},
    {"SECRET_KEY_BASE", String.duplicate("k", 64)},
    {"SLIPDOCK_SMTP_HOST", "relay.example.com"}
  ]

  # Documentation ranges (RFC 5737), not the private ones a real deployment
  # would list: NothingPersonalTest keeps private addresses out of the repo,
  # and the parsing doesn't look at what the entries are.
  @list "198.51.100.0/24, 203.0.113.0/24,"
  @parsed ["198.51.100.0/24", "203.0.113.0/24"]

  defp read_runtime(env) do
    script = ~S"""
    s = Config.Reader.read!("config/runtime.exs", env: :prod)[:slipdock]

    out = %{
      egress: Keyword.fetch(s, :egress),
      trusted_proxies: Keyword.fetch(s, :trusted_proxies)
    }

    IO.puts("RESULT " <> Base.encode64(:erlang.term_to_binary(out)))
    """

    assigns = Enum.map(@base ++ env, fn {name, value} -> "#{name}=#{value}" end)
    ebin = Application.app_dir(:slipdock, "ebin")

    # Through env(1), with -u for the variables left unset, so one set in the
    # shell running the tests can't reach the child either.
    unsets =
      for name <- ~w(SLIPDOCK_EGRESS_ALLOW SLIPDOCK_TRUSTED_PROXIES),
          not List.keymember?(env, name, 0),
          do: ["-u", name]

    {out, 0} =
      System.cmd(
        "env",
        List.flatten(unsets) ++
          assigns ++ [System.find_executable("elixir"), "-pa", ebin, "-e", script],
        stderr_to_stdout: true
      )

    [_, encoded] = Regex.run(~r/^RESULT (.*)$/m, out)
    encoded |> Base.decode64!() |> :erlang.binary_to_term()
  end

  describe "SLIPDOCK_EGRESS_ALLOW" do
    for {value, expected} <- [
          {:unset, :error},
          {"all", {:ok, [allow: :all]}},
          {@list, {:ok, [allow: @parsed]}},
          {" 198.51.100.0/24 ", {:ok, [allow: ["198.51.100.0/24"]]}}
        ] do
      test "#{inspect(value)} gives #{inspect(expected)}" do
        env =
          if unquote(value) == :unset, do: [], else: [{"SLIPDOCK_EGRESS_ALLOW", unquote(value)}]

        assert read_runtime(env).egress == unquote(Macro.escape(expected))
      end
    end
  end

  describe "SLIPDOCK_TRUSTED_PROXIES" do
    for {value, expected} <- [
          {:unset, :error},
          {"none", {:ok, []}},
          {@list, {:ok, @parsed}},
          {"local, 198.51.100.0/24", {:ok, ["local", "198.51.100.0/24"]}}
        ] do
      test "#{inspect(value)} gives #{inspect(expected)}" do
        env =
          if unquote(value) == :unset,
            do: [],
            else: [{"SLIPDOCK_TRUSTED_PROXIES", unquote(value)}]

        assert read_runtime(env).trusted_proxies == unquote(Macro.escape(expected))
      end
    end
  end

  test "each variable is read on its own: setting one leaves the other unset" do
    config = read_runtime([{"SLIPDOCK_EGRESS_ALLOW", "all"}])
    assert config.trusted_proxies == :error

    config = read_runtime([{"SLIPDOCK_TRUSTED_PROXIES", "none"}])
    assert config.egress == :error
  end
end
