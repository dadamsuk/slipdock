defmodule Slipdock.RuntimeSmtpConfigTest do
  # config/runtime.exs as a dev server reads it, evaluated in a separate
  # `elixir` so the .env it loads and the variables it sets stay out of this
  # VM. A blank SLIPDOCK_SMTP_HOST is how tools/e2e/lib.sh keeps its servers
  # from posting mail to e2e@example.com through a real relay.
  use ExUnit.Case, async: true

  defp mailer_adapter(env) do
    script = ~S"""
    config = Config.Reader.read!("config/runtime.exs", env: :dev)
    IO.puts("ADAPTER " <> inspect(config[:slipdock][Slipdock.Mailer][:adapter]))
    IO.puts("SEED " <> inspect(config[:slipdock][:seed_smtp] != nil))
    """

    # Through env(1): System.cmd drops a variable whose value is empty
    # rather than setting it blank, and blank is the case under test.
    assigns = Enum.map(env, fn {name, value} -> "#{name}=#{value}" end)

    {out, 0} =
      System.cmd("env", assigns ++ [System.find_executable("elixir"), "-e", script],
        stderr_to_stdout: true
      )

    [_, adapter] = Regex.run(~r/^ADAPTER (.*)$/m, out)
    [_, seed] = Regex.run(~r/^SEED (.*)$/m, out)
    {adapter, seed == "true"}
  end

  test "a host makes the mailer SMTP and seeds the settings" do
    assert mailer_adapter([{"SLIPDOCK_SMTP_HOST", "relay.example.com"}]) ==
             {"Swoosh.Adapters.SMTP", true}
  end

  test "a blank host turns SMTP off, even with an old KANBAN_SMTP_HOST about" do
    assert mailer_adapter([
             {"SLIPDOCK_SMTP_HOST", ""},
             {"KANBAN_SMTP_HOST", "relay.example.com"}
           ]) == {"nil", false}
  end

  test "so does one of only spaces" do
    assert mailer_adapter([{"SLIPDOCK_SMTP_HOST", "  "}]) == {"nil", false}
  end
end
