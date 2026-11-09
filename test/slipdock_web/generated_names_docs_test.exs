defmodule SlipdockWeb.GeneratedNamesDocsTest do
  @moduledoc """
  What the docs and the skills say about names things give themselves (#1595).
  """
  use Slipdock.DataCase, async: true

  alias SlipdockWeb.APIGuide

  @root Path.expand("../..", __DIR__)
  defp read(path), do: Slipdock.DocsText.read!(Path.join(@root, path))

  test "the skills that file cards ask for short titles, in their own copies" do
    for skill <- ~w(slipdock-work slipdock-loop slipdock-docs) do
      text = read("priv/skills/#{skill}/SKILL.md") |> String.replace(~r/\s+/, " ")
      assert text =~ "about 60 characters at most", skill
      assert text =~ "`<Series> <n>: <what>`", skill
      assert text =~ "description", skill
    end
  end

  test "the agent docs and the guide say the same" do
    {:ok, guide} = APIGuide.section("all", [])
    guide = String.replace(guide, ~r/\s+/, " ")
    assert guide =~ "about 60 characters at most"
    assert guide =~ "`<Series> <n>: <what>`"
    assert guide =~ "`Cards/<short>/<short>.md`"

    agents = read("docs/agents.md") |> String.replace(~r/\s+/, " ")
    assert agents =~ "about 60 characters at most"
    # The pass-log example was served with the shell runners, retired (#2582).
    refute agents =~ "`/runner/examples/passlog.sh`"
  end

  test "the short guide stays as it was: this lives in the full one" do
    refute APIGuide.short() =~ "`<Series> <n>: <what>`"
  end

  test "the manual and README name what's written" do
    manual = read("docs/manual.md")
    refute manual =~ "*Decisions / Pricing sync · 7 Oct 2026*"
    refute manual =~ "`/runner/examples/passlog.sh`"
    assert manual =~ "`Weekly review 2026-11-02`"
    assert manual =~ "`<rule>: <card> <date>`"

    readme = read("README.md")
    assert readme =~ "`Cards/<short>/<short>.md`"
    assert readme =~ "`Pass <card> (<YYYY-MM-DD HH.MM>)`"
  end

  test "the guide no longer calls a meeting's page Decisions /" do
    guide = APIGuide.section("all", []) |> elem(1)
    refute guide =~ "*Decisions / <meeting>"
  end
end
