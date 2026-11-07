defmodule Slipdock.RuntimeSwitchesTest do
  # The two switches that guard sign-in, SLIPDOCK_LOGIN_FALLBACK and
  # SLIPDOCK_AGENTIC_LOGIN, as config/runtime.exs reads them (#1933): the shared
  # on and off words in any case, and anything else named in a warning at boot
  # with the switch left where it is safe. Read as prod reads it, in a separate
  # `elixir`, so the variables set here stay out of this VM.
  use ExUnit.Case, async: true

  @base [
    {"DATABASE_URL", "ecto://db.example.com/slipdock"},
    {"SECRET_KEY_BASE", String.duplicate("k", 64)},
    {"SLIPDOCK_SMTP_HOST", "relay.example.com"}
  ]

  defp read_runtime(env) do
    script = ~S"""
    s = Config.Reader.read!("config/runtime.exs", env: :prod)[:slipdock]
    out = %{login_fallback: s[:login_fallback], agentic_login: s[:agentic_login]}
    IO.puts("RESULT " <> Base.encode64(:erlang.term_to_binary(out)))
    """

    assigns = Enum.map(@base ++ env, fn {name, value} -> "#{name}=#{value}" end)
    ebin = Application.app_dir(:slipdock, "ebin")

    {out, 0} =
      System.cmd(
        "env",
        assigns ++ [System.find_executable("elixir"), "-pa", ebin, "-e", script],
        stderr_to_stdout: true
      )

    [_, encoded] = Regex.run(~r/^RESULT (.*)$/m, out)
    {encoded |> Base.decode64!() |> :erlang.binary_to_term(), out}
  end

  @off_words ["0", "false", "off", "no", "none"]
  @on_words ["1", "true", "yes", "on"]

  describe "SLIPDOCK_LOGIN_FALLBACK" do
    for word <-
          Enum.uniq(@off_words ++ Enum.map(@off_words, &String.upcase/1) ++ ["False", " No "]) do
      test "#{inspect(word)} turns the sign-in-code file off, without a warning" do
        {config, out} = read_runtime([{"SLIPDOCK_LOGIN_FALLBACK", unquote(word)}])
        assert config.login_fallback == false
        refute out =~ "SLIPDOCK_LOGIN_FALLBACK"
      end
    end

    for word <- @on_words ++ ["TRUE", "On"] do
      test "#{inspect(word)} leaves the file to the settings, without a warning" do
        {config, out} = read_runtime([{"SLIPDOCK_LOGIN_FALLBACK", unquote(word)}])
        assert config.login_fallback == nil
        refute out =~ "SLIPDOCK_LOGIN_FALLBACK"
      end
    end

    for word <- ["disabled", "maybe", "n", "0ff"] do
      test "#{inspect(word)} warns at boot and turns the file off" do
        {config, out} = read_runtime([{"SLIPDOCK_LOGIN_FALLBACK", unquote(word)}])
        assert config.login_fallback == false
        assert out =~ ~s(warning: SLIPDOCK_LOGIN_FALLBACK=#{inspect(unquote(word))} is not)
        assert out =~ "read as off"
      end
    end

    test "unset or blank leaves the file to the settings, without a warning" do
      for env <- [[], [{"SLIPDOCK_LOGIN_FALLBACK", "  "}]] do
        {config, out} = read_runtime(env)
        assert config.login_fallback == nil
        refute out =~ "SLIPDOCK_LOGIN_FALLBACK"
      end
    end
  end

  describe "SLIPDOCK_AGENTIC_LOGIN" do
    test "an on word turns it on, without a warning" do
      for word <- ["true", "Yes"] do
        {config, out} = read_runtime([{"SLIPDOCK_AGENTIC_LOGIN", word}])
        assert config.agentic_login == true
        refute out =~ "SLIPDOCK_AGENTIC_LOGIN"
      end
    end

    test "an off word leaves it off, without a warning" do
      for word <- ["off", "FALSE"] do
        {config, out} = read_runtime([{"SLIPDOCK_AGENTIC_LOGIN", word}])
        assert config.agentic_login == nil
        refute out =~ "SLIPDOCK_AGENTIC_LOGIN"
      end
    end

    for word <- ["enabled", "y", "tru"] do
      test "#{inspect(word)} warns at boot and leaves it off" do
        {config, out} = read_runtime([{"SLIPDOCK_AGENTIC_LOGIN", unquote(word)}])
        assert config.agentic_login == nil
        assert out =~ ~s(warning: SLIPDOCK_AGENTIC_LOGIN=#{inspect(unquote(word))} is not)
        assert out =~ "read as off"
      end
    end
  end

  test "the warning names only the variable whose value was not recognised" do
    {config, out} =
      read_runtime([{"SLIPDOCK_LOGIN_FALLBACK", "no"}, {"SLIPDOCK_AGENTIC_LOGIN", "sometimes"}])

    assert config == %{login_fallback: false, agentic_login: nil}
    assert out =~ "warning: SLIPDOCK_AGENTIC_LOGIN="
    refute out =~ "SLIPDOCK_LOGIN_FALLBACK"
  end
end
