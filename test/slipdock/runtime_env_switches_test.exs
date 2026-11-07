defmodule Slipdock.RuntimeEnvSwitchesTest do
  # config/runtime.exs reads every on/off variable with the same words (#1932):
  # on is 1/true/yes/on, off is 0/false/no/off/none, in any case and trimmed,
  # and blank is unset. Read as prod reads it, in a separate `elixir` so the
  # variables set here stay out of this VM.
  use ExUnit.Case, async: true

  @switches ~w(
    SLIPDOCK_SHARED_AI_KEY_ADMINS_ONLY SLIPDOCK_OPEN_SIGNUP SLIPDOCK_AGENTIC_LOGIN
    SLIPDOCK_LOGIN_FALLBACK SLIPDOCK_WELCOME_BOARD SLIPDOCK_SMTP_TLS_VERIFY
    SLIPDOCK_INVITES_CREATE_ACCOUNTS SLIPDOCK_TRIAL_DAYS SLIPDOCK_BOARD_LIMIT
    SLIPDOCK_ITEM_LIMIT SLIPDOCK_STORAGE_LIMIT_MB PHX_SERVER DATABASE_SSL
    DATABASE_SSL_VERIFY ECTO_IPV6 SLIPDOCK_CHECK_ORIGIN
  )

  @base [
    {"DATABASE_URL", "ecto://db.example.com/slipdock"},
    {"SECRET_KEY_BASE", String.duplicate("k", 64)},
    {"SLIPDOCK_SMTP_HOST", "relay.example.com"},
    {"SLIPDOCK_SIGNUP_ALLOW", "example.com"}
  ]

  defp read_runtime(env) do
    script = ~S"""
    c = Config.Reader.read!("config/runtime.exs", env: :prod)
    s = c[:slipdock]
    settings = s[:settings] || []
    repo = s[Slipdock.Repo]

    out = %{
      admins_only: s[:ai][:shared_key_for_admins_only],
      open_signup: s[:signups][:open],
      agentic_login: s[:agentic_login],
      login_fallback: s[:login_fallback],
      welcome_board: s[:welcome_board],
      smtp_tls_verify: s[:smtp_tls_verify],
      invites: settings[:invites_create_accounts],
      limits:
        Enum.map(
          [:trial_enabled, :board_limit_enabled, :item_limit_enabled, :storage_limit_enabled],
          &settings[&1]
        ),
      limit_values:
        Enum.map([:trial_days, :board_limit, :item_limit, :storage_limit_mb], &settings[&1]),
      server: s[SlipdockWeb.Endpoint][:server],
      ssl: repo[:ssl] && repo[:ssl][:verify],
      ipv6: repo[:socket_options],
      check_origin: s[SlipdockWeb.Endpoint][:check_origin] != false,
      smtp_ports: {s[Slipdock.Mailer][:port], s[:seed_smtp][:port]}
    }

    IO.puts("RESULT " <> Base.encode64(:erlang.term_to_binary(out)))
    """

    # Through env(1): System.cmd drops a variable whose value is empty rather
    # than setting it blank, and blank is one of the cases under test.
    assigns = Enum.map(@base ++ env, fn {name, value} -> "#{name}=#{value}" end)
    ebin = Application.app_dir(:slipdock, "ebin")

    {out, status} =
      System.cmd(
        "env",
        assigns ++ [System.find_executable("elixir"), "-pa", ebin, "-e", script],
        stderr_to_stdout: true
      )

    case Regex.run(~r/^RESULT (.*)$/m, out) do
      [_, encoded] -> {:ok, encoded |> Base.decode64!() |> :erlang.binary_to_term()}
      nil -> {:error, status, out}
    end
  end

  defp all_switches(word), do: Enum.map(@switches, &{&1, word})

  @on %{
    admins_only: true,
    open_signup: true,
    agentic_login: true,
    login_fallback: nil,
    welcome_board: nil,
    smtp_tls_verify: true,
    invites: true,
    limits: [true, true, true, true],
    server: true,
    ssl: :verify_peer,
    ipv6: [:inet6],
    check_origin: true
  }

  @off %{
    admins_only: nil,
    open_signup: false,
    agentic_login: nil,
    login_fallback: false,
    welcome_board: false,
    smtp_tls_verify: false,
    invites: false,
    limits: [false, false, false, false],
    server: nil,
    ssl: nil,
    ipv6: [],
    check_origin: false
  }

  for word <- ["1", "true", "yes", "on", "TRUE", " Yes ", "On"] do
    test "#{inspect(word)} turns every switch on" do
      assert {:ok, config} = read_runtime(all_switches(unquote(word)))
      assert Map.take(config, Map.keys(@on)) == @on
    end
  end

  for word <- ["0", "false", "no", "off", "none", "OFF", " None "] do
    test "#{inspect(word)} turns every switch off" do
      assert {:ok, config} = read_runtime(all_switches(unquote(word)))
      assert Map.take(config, Map.keys(@off)) == @off
    end
  end

  test "blank, or only spaces, is the same as unset: every switch keeps its default" do
    defaults = %{
      admins_only: nil,
      open_signup: false,
      agentic_login: nil,
      login_fallback: nil,
      welcome_board: nil,
      smtp_tls_verify: true,
      invites: nil,
      limits: [nil, nil, nil, nil],
      server: nil,
      ssl: nil,
      ipv6: [],
      check_origin: true
    }

    for word <- ["", "   "] do
      assert {:ok, config} = read_runtime(all_switches(word))
      assert Map.take(config, Map.keys(defaults)) == defaults, "for #{inspect(word)}"
    end
  end

  @limits ~w(SLIPDOCK_TRIAL_DAYS SLIPDOCK_BOARD_LIMIT SLIPDOCK_ITEM_LIMIT SLIPDOCK_STORAGE_LIMIT_MB)

  test "a word in neither list leaves an on-switch off and an off-switch on" do
    env = for {name, _} = pair <- all_switches("maybe"), name not in @limits, do: pair
    assert {:ok, config} = read_runtime(env)
    assert config.agentic_login == nil
    assert config.open_signup == false
    assert config.welcome_board == nil
    assert config.smtp_tls_verify == true
    assert config.invites == nil
  end

  describe "the limit variables" do
    test "a number seeds the limit and turns it on, trimmed" do
      env = Enum.map(@limits, &{&1, " 30 "})
      assert {:ok, config} = read_runtime(env)
      assert config.limit_values == [30, 30, 30, 30]
      assert config.limits == [true, true, true, true]
    end

    test "an on word that isn't a number keeps the limit on at its default" do
      assert {:ok, config} = read_runtime(Enum.map(@limits, &{&1, "yes"}))
      assert config.limit_values == [nil, nil, nil, nil]
      assert config.limits == [true, true, true, true]
    end

    test "an off word seeds no number and turns the limit off" do
      assert {:ok, config} = read_runtime(Enum.map(@limits, &{&1, "none"}))
      assert config.limit_values == [nil, nil, nil, nil]
      assert config.limits == [false, false, false, false]
    end

    for limit <-
          ~w(SLIPDOCK_TRIAL_DAYS SLIPDOCK_BOARD_LIMIT SLIPDOCK_ITEM_LIMIT SLIPDOCK_STORAGE_LIMIT_MB),
        value <- ["1000abc", "maybe"] do
      test "#{limit}=#{inspect(value)} isn't a number: it stops the boot and names the variable" do
        assert {:error, status, out} = read_runtime([{unquote(limit), unquote(value)}])
        assert status != 0
        assert out =~ ~s(#{unquote(limit)} must be a whole number, not #{inspect(unquote(value))})
      end
    end

    for value <- ["-5", " -1 "] do
      test "a negative limit (#{inspect(value)}) stops the boot rather than being dropped" do
        assert {:error, status, out} = read_runtime([{"SLIPDOCK_BOARD_LIMIT", unquote(value)}])
        assert status != 0

        assert out =~
                 ~s(SLIPDOCK_BOARD_LIMIT must be a positive whole number or an off word, not "#{String.trim(unquote(value))}")
      end
    end
  end

  describe "SLIPDOCK_SMTP_PORT" do
    test "is read once, for the mailer and the seeded settings alike" do
      assert {:ok, %{smtp_ports: {2525, 2525}}} =
               read_runtime([{"SLIPDOCK_SMTP_PORT", " 2525 "}])
    end

    test "defaults to 587 when unset or blank" do
      assert {:ok, %{smtp_ports: {587, 587}}} = read_runtime([{"SLIPDOCK_SMTP_PORT", ""}])
    end

    test "that isn't a number stops the boot and names the variable" do
      assert {:error, status, out} = read_runtime([{"SLIPDOCK_SMTP_PORT", "smtp"}])
      assert status != 0
      assert out =~ ~s(SLIPDOCK_SMTP_PORT must be a whole number, not "smtp")
    end
  end
end
