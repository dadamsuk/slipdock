defmodule Slipdock.CiWorkflowTest do
  @moduledoc """
  The static checks in .github/workflows/ci.yml. Each one started at zero
  findings, so it only protects anything while it still runs on every pull
  request: these are the lines whose loss would go unnoticed until a finding
  slipped through.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)
  @ci File.read!(Path.join(@root, ".github/workflows/ci.yml"))

  # Comments stripped, so a step only mentioned in a comment does not count.
  defp lines(text),
    do:
      text
      |> String.split("\n")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "#")))

  # One job's lines: from `  <name>:` to the next job at the same indent.
  defp job(name) do
    [_, rest] = String.split(@ci, "\n  #{name}:\n", parts: 2)
    body = rest |> String.split(~r/\n  [a-z][a-z0-9_-]*:\n/, parts: 2) |> hd()
    lines(body)
  end

  defp has?(lines, line), do: Enum.member?(lines, line)

  # A step's `run:` line inside a job, as written.
  defp runs?(job, command), do: has?(job, "run: #{command}")

  test "the workflow runs on every pull request" do
    assert has?(lines(@ci), "pull_request:")
  end

  test "no static check is allowed to fail quietly" do
    refute Enum.any?(lines(@ci), &(&1 =~ "continue-on-error"))
  end

  test "the static checks job is not skipped on any event" do
    refute Enum.any?(job("static"), &String.starts_with?(&1, "if:"))
  end

  describe "dependency audit" do
    test "the app's dependencies are checked for retired packages and advisories" do
      static = job("static")
      assert runs?(static, "mix hex.audit")
      assert runs?(static, "mix deps.audit")
    end

    test "the CLI's dependencies are checked too" do
      assert runs?(job("cli"), "mix hex.audit")
    end

    test "mix_audit is a dependency in the environment CI runs in" do
      mix_exs = File.read!(Path.join(@root, "mix.exs"))
      assert mix_exs =~ ~r/\{:mix_audit, "[^"]+", only: \[[^\]]*:test[^\]]*\]/
      assert has?(lines(@ci), "MIX_ENV: test")
    end
  end

  describe "sobelow" do
    test "runs with its config, failing on any finding" do
      assert runs?(job("static"), "mix sobelow --config")

      {conf, _} = Code.eval_file(Path.join(@root, ".sobelow-conf"))
      assert conf[:exit] == "low"
      assert conf[:threshold] == "low"
      assert conf[:skip] == true
    end

    test "every type ignored in .sobelow-conf has its reason there" do
      {conf, _} = Code.eval_file(Path.join(@root, ".sobelow-conf"))
      text = File.read!(Path.join(@root, ".sobelow-conf"))

      for type <- conf[:ignore] do
        assert text =~ ~r/^#\s+#{Regex.escape(type)}\s+\S/m, "no reason for #{type}"
      end
    end

    test "every skip in the code has a reason on the line above" do
      skips =
        for file <- Path.wildcard(Path.join(@root, "lib/**/*.ex")),
            [prev, line] <- file |> File.read!() |> String.split("\n") |> Enum.chunk_every(2, 1),
            line =~ ~r/#\s*sobelow_skip\s*\[/,
            do: {Path.relative_to(file, @root), String.trim(prev)}

      assert skips != []

      for {file, prev} <- skips do
        assert String.starts_with?(prev, "# Not a hole: "), "#{file}: a skip with no reason"
      end
    end

    test "no fingerprint skips, which would break on the next edit above them" do
      refute File.exists?(Path.join(@root, ".sobelow-skips"))
    end
  end

  describe "gitleaks" do
    test "scans the commits each pull request adds, failing on a hit" do
      secrets = job("secrets")

      assert has?(secrets, "if: github.event_name == 'pull_request'")
      assert has?(secrets, "fetch-depth: 0")
      assert has?(secrets, "BASE: ${{ github.event.pull_request.base.sha }}")
      assert has?(secrets, "HEAD: ${{ github.event.pull_request.head.sha }}")

      assert runs?(
               secrets,
               ~s(/tmp/gitleaks git --redact --no-banner --verbose --log-opts="$BASE..$HEAD" .)
             )
    end

    test "the binary is checked against its published checksum" do
      assert Enum.any?(
               job("secrets"),
               &(&1 =~ ~r/^echo "[0-9a-f]{64}  \/tmp\/gitleaks.tgz" \| sha256sum -c -$/)
             )
    end

    test "every allowlist in .gitleaks.toml says why, and extends gitleaks' own rules" do
      toml = File.read!(Path.join(@root, ".gitleaks.toml"))
      assert toml =~ ~r/^\[extend\]\nuseDefault = true$/m

      blocks = toml |> String.split("[[allowlists]]") |> tl()
      assert blocks != []

      for block <- blocks do
        assert block =~ ~r/^description = "[^"]{20,}"$/m
      end
    end
  end

  describe "credo" do
    test "lints only what a change adds, against where it left main" do
      static = job("static")

      assert runs?(
               static,
               ~s(mix credo diff --from-git-merge-base origin/main --config-file "$PWD/.credo.exs")
             )

      # The merge base needs the history.
      assert has?(static, "fetch-depth: 0")
    end

    test ".credo.exs loads our own checks and gives a reason for each tuning" do
      text = File.read!(Path.join(@root, ".credo.exs"))
      {config, _} = Code.eval_string(text)
      [default] = config.configs

      assert default.requires == ["credo/checks/"]

      assert {Slipdock.Credo.InOutsideGuard, _} =
               List.keyfind(default.checks.enabled, Slipdock.Credo.InOutsideGuard, 0)

      # Our own tunings of credo's defaults each have a comment above them.
      for name <- ["Slipdock.Credo.InOutsideGuard", "Credo.Check.Readability.LargeNumbers"] do
        assert text =~ ~r/#[^\n]*\n\s*\{#{Regex.escape(name)}, \[[^\]]/,
               "#{name} is tuned without a reason"
      end

      # Nothing credo turns on by default is off, and the opt-ins left off say why.
      assert text =~ "Nothing that credo turns on by default is off here."
    end
  end
end
