defmodule Slipdock.EnvExampleTest do
  @moduledoc """
  `.env.example` lists every environment variable the app reads (OPS-9,
  #2609). Someone setting up a server copies it, so a variable left out of it
  is a setting nobody finds. This holds it to `config/runtime.exs`: every
  variable name quoted in that file's code (`System.get_env("X")`, the
  `env_*`, `positive_env` and `switch_env` helpers' first argument, the AI
  `from_env` list) must appear in `.env.example` as a `# X=` line.

  Comment lines in `runtime.exs` are skipped, so the commented-out Phoenix SSL
  example's `SOME_APP_SSL_*` names don't count.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)

  # A quoted environment variable name: capitals, digits and underscores,
  # neither starting with a digit nor ending in an underscore (so the
  # `"KANBAN_" <> rest` prefix match isn't one).
  @quoted_name ~r/"([A-Z][A-Z0-9_]*[A-Z0-9])"/

  # A line of .env.example naming a variable: `# NAME=value` or `NAME=value`.
  @listed_name ~r/^#?\s*([A-Z][A-Z0-9_]*[A-Z0-9])=/m

  defp read(path), do: File.read!(Path.join(@root, path))

  @doc false
  def read_names(source) do
    source
    |> String.split("\n")
    |> Enum.reject(&String.starts_with?(String.trim_leading(&1), "#"))
    |> Enum.flat_map(&Regex.scan(@quoted_name, &1, capture: :all_but_first))
    |> List.flatten()
    |> MapSet.new()
  end

  @doc false
  def listed_names(example) do
    @listed_name
    |> Regex.scan(example, capture: :all_but_first)
    |> List.flatten()
    |> MapSet.new()
  end

  defp missing(source, example) do
    source |> read_names() |> MapSet.difference(listed_names(example)) |> Enum.sort()
  end

  describe "the check itself" do
    test "finds a name through System.get_env and each kind of helper" do
      source = """
      if key = System.get_env("ONE_KEY") do
      x = env_int.("PORT", 4000)
      y = positive_env.("SLIPDOCK_SOME_LIMIT")
      from_env: for({k, var} <- [model: "SLIPDOCK_AI_THING"], System.get_env(var), do: k)
      """

      assert read_names(source) ==
               MapSet.new(~w(ONE_KEY PORT SLIPDOCK_SOME_LIMIT SLIPDOCK_AI_THING))
    end

    test "skips comment lines, prefixes and strings that aren't names" do
      source = """
      # keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
        #  certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
      for {"KANBAN_" <> rest = old, value} <- System.get_env(), do: rest
      case mode do "open" -> :open end
      """

      assert read_names(source) == MapSet.new()
    end

    test "reads commented and uncommented lines of the example" do
      example = """
      # Port to listen on.
      # PORT=4000
      #SLIPDOCK_A=1
      SLIPDOCK_B=
      # SLIPDOCK_AI_BASE_URL=http://llm.local:1234/v1     # LM Studio
      # Not a VARIABLE= line in prose.
      """

      assert listed_names(example) ==
               MapSet.new(~w(PORT SLIPDOCK_A SLIPDOCK_B SLIPDOCK_AI_BASE_URL))
    end

    test "names a variable runtime.exs reads that the example leaves out" do
      source = ~s|smtp = System.get_env("SLIPDOCK_SMTP_FROM")\nport = env_int.("PORT", 4000)|
      example = "# PORT=4000\n# SLIPDOCK_SMTP_FROM_NAME=x\n"

      assert missing(source, example) == ["SLIPDOCK_SMTP_FROM"]
    end
  end

  test "every variable config/runtime.exs reads is in .env.example" do
    source = read("config/runtime.exs")
    names = read_names(source)

    # The scan has found the file's variables at all: a regex broken into
    # finding nothing would pass the check below vacuously.
    assert MapSet.member?(names, "SECRET_KEY_BASE")
    assert MapSet.member?(names, "SLIPDOCK_TRIAL_DAYS")
    assert MapSet.size(names) > 50

    assert missing(source, read(".env.example")) == [],
           "config/runtime.exs reads these, but .env.example doesn't list them " <>
             "(OPS-9): add a commented `# NAME=default` line for each, with a line " <>
             "on what it does, beside its neighbours."
  end
end
