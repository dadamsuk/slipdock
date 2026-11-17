defmodule Slipdock.ToolVersionsTest do
  @moduledoc """
  One toolchain, named the same everywhere (#3344). `mix.exs` requires an
  Elixir minor, CI (`ci.yml`, `release.yml`) installs that minor and an OTP
  major, the `Dockerfile` pins the exact patch the release is built with,
  `.tool-versions` pins that patch for asdf and mise, and `README.md` and
  `CONTRIBUTING.md` tell a contributor what to install. Each fact is read
  from every place that states it, so a bump in one fails here until the
  rest follow. Go and Node come from CI too: Node's major from
  `setup-node`, and Go as CI's `stable`, which `.tool-versions` can only pin,
  so the check is that it is at least the daemon's `go.mod` floor.

  And the `KANBAN_*` environment variables, renamed `SLIPDOCK_*`, are named
  nowhere in the docs but `UPGRADING.md`, whose table is the rename itself.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)

  defp read(path), do: File.read!(Path.join(@root, path))

  defp workflows, do: Enum.map(~w(ci.yml release.yml), &read(".github/workflows/" <> &1))

  # Every value a `key: "value"` line gives across the workflows.
  defp workflow_values(key) do
    workflows()
    |> Enum.flat_map(
      &Regex.scan(~r/^\s*#{key}:\s*"?([^"\s]+)"?\s*$/m, &1, capture: :all_but_first)
    )
    |> List.flatten()
    |> Enum.uniq()
  end

  defp tool_versions do
    for line <- String.split(read(".tool-versions"), "\n", trim: true),
        not String.starts_with?(line, "#"),
        into: %{} do
      [tool, version] = String.split(line, ~r/\s+/, trim: true)
      {tool, version}
    end
  end

  defp elixir_minor do
    [minor] = Regex.run(~r/elixir: "~> (\d+\.\d+)"/, read("mix.exs"), capture: :all_but_first)
    minor
  end

  defp otp_major do
    [major] = workflow_values("otp-version")
    major
  end

  defp version_list(v), do: v |> String.split(".") |> Enum.map(&String.to_integer/1)

  test "CI installs the Elixir minor mix.exs requires, and one OTP major" do
    assert workflow_values("elixir-version") == [elixir_minor()]
    assert [_one] = workflow_values("otp-version")
  end

  test "the Dockerfile and .tool-versions pin the same Elixir and Erlang, on CI's minor and major" do
    [elixir, erlang] =
      Regex.run(~r/hexpm\/elixir:(\d+\.\d+\.\d+)-erlang-([\d.]+)-/, read("Dockerfile"),
        capture: :all_but_first
      )

    tools = tool_versions()
    assert tools["elixir"] == "#{elixir}-otp-#{otp_major()}"
    assert tools["erlang"] == erlang
    assert String.starts_with?(elixir, elixir_minor() <> ".")
    assert String.starts_with?(erlang, otp_major() <> ".")
  end

  test ".tool-versions pins Node on CI's major, and a Go no older than go.mod's floor" do
    tools = tool_versions()

    assert [node_major] = workflow_values("node-version")
    assert String.starts_with?(tools["nodejs"], node_major <> ".")

    assert workflow_values("go-version") == ["stable"]
    [floor] = Regex.run(~r/^go (\S+)$/m, read("daemon/go.mod"), capture: :all_but_first)
    assert version_list(tools["golang"]) >= version_list(floor)
  end

  test "README and CONTRIBUTING name the Elixir and OTP that mix.exs and CI do, and no other" do
    for doc <- ~w(README.md CONTRIBUTING.md) do
      text = read(doc)
      assert text =~ "Elixir #{elixir_minor()} on Erlang/OTP #{otp_major()}", doc

      assert Regex.scan(~r/Elixir (\d+\.\d+)/, text, capture: :all_but_first)
             |> List.flatten()
             |> Enum.uniq() ==
               [elixir_minor()],
             "#{doc} names another Elixir version"
    end
  end

  test "no doc names a KANBAN_* variable but UPGRADING.md's rename table" do
    docs =
      ~w(README.md CONTRIBUTING.md SECURITY.md AGENTS.md CLAUDE.md) ++
        Path.wildcard(Path.join(@root, "docs/**/*.md"))

    offenders =
      for doc <- docs,
          path = if(Path.type(doc) == :absolute, do: doc, else: Path.join(@root, doc)),
          File.exists?(path),
          File.read!(path) =~ ~r/\bKANBAN_[A-Z]/,
          do: Path.relative_to(path, @root)

    assert offenders == []
  end
end
