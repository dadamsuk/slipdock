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
end
