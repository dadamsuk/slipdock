defmodule SlipdockWeb.HealthDocsTest do
  @moduledoc """
  The health monitor as the docs describe it (W-2310): the guide's own
  section (only its index line in the short guide), the manual's section with
  every detector in its table, and docs/agents.md.
  """
  use SlipdockWeb.ConnCase, async: true

  @root Path.expand("../..", __DIR__)
  defp read(path), do: File.read!(Path.join(@root, path))

  test "the guide has a section of its own, and the short guide only indexes it" do
    assert {"health", "Health monitor", text} =
             List.keyfind(SlipdockWeb.APIGuide.sections(), "health", 0)

    assert text =~ "`stuck` flag"
    assert text =~ "`health_flagged`"
    assert text =~ "GET /api/boards/:board/health"
    assert text =~ "slipdock health <board>"

    short = SlipdockWeb.APIGuide.short()
    assert short =~ "`health`"
    refute short =~ "## Health monitor"
    assert SlipdockWeb.APIGuide.markdown() =~ "`starred`, `stuck`."
  end

  test "the manual has the section, the commands, the endpoints and every detector" do
    manual = read("docs/manual.md")
    assert manual =~ ~r/^## The health monitor$/m
    assert manual =~ "[The health monitor](#the-health-monitor)"
    assert manual =~ "slipdock health settings ops no_runner minutes=30"
    assert manual =~ "PATCH /api/boards/:board/health/settings"
    assert manual =~ "**The health monitor needs a person**"

    for detector <- Slipdock.Health.detectors() do
      assert manual =~ "| `#{detector.key()}` |",
             "the manual's detector table lacks #{detector.key()}"
    end
  end

  test "docs/agents.md says what an agent does with a stuck card" do
    agents = read("docs/agents.md")
    assert agents =~ "**The health monitor.**"
    assert agents =~ "manual.md#the-health-monitor"
    assert agents =~ "leaves the flag alone"
  end

  test "README links the manual's section, and the slipdock skill knows stuck and health" do
    assert read("README.md") =~ "docs/manual.md#the-health-monitor"
    skill = read("priv/skills/slipdock/SKILL.md")
    assert skill =~ "flagged blocked review waiting starred stuck"
    assert skill =~ "stuck is the health monitor's: leave it for a person"
    assert skill =~ "slipdock health <board> [--run]"
    assert skill =~ "slipdock health settings <board>"
  end
end
