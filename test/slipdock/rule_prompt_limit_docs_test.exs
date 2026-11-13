defmodule Slipdock.RulePromptLimitDocsTest do
  # What a rule's runner prompt may be (#2910): the runners' cap less the
  # text every job's prompt ends with. The docs give it to the nearest
  # hundred below, so they go stale only when that text grows or shrinks by
  # about that much, and this fails when they do. Reads docs/, the API guide
  # and priv/skills/, so it is on test/repo_checks.txt.
  use ExUnit.Case, async: true

  import Slipdock.DocsFacts, only: [assert_states: 2]

  alias Slipdock.Automations.Runner
  alias Slipdock.Runners

  @root Path.expand("../..", __DIR__)

  defp read(path),
    do: @root |> Path.join(path) |> Slipdock.DocsText.read!() |> String.replace(~r/\s+/, " ")

  defp with_commas(n) do
    n
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end

  # 17,835 is said as "about 17,800".
  defp about, do: "about #{with_commas(div(Runner.max_rule_prompt(), 100) * 100)} bytes"
  defp cap, do: "#{with_commas(Runners.limits().max_prompt)}"

  test "the figure is the cap less the fixed text, said to the hundred below" do
    assert with_commas(17_835) == "17,835"
    assert with_commas(999) == "999"
    assert with_commas(1_000_000) == "1,000,000"
    assert about() =~ ~r/^about \d{1,2},\d00 bytes$/
    assert cap() == "20,000"
  end

  for path <- [
        "docs/tool-packages.md",
        "docs/manual/runners.md",
        "docs/agents.md",
        "priv/skills/slipdock/SKILL.md",
        "lib/slipdock_web/api_guide.ex"
      ] do
    test "#{path} gives a rule's prompt its real limit, and the cap it comes from" do
      text = read(unquote(path))

      assert text =~ about(),
             "#{unquote(path)} should say a rule's prompt is at most #{about()} " <>
               "(Runner.max_rule_prompt/0 is #{Runner.max_rule_prompt()})"

      assert text =~ cap()
      assert_states(text, "a prompt one over is refused when the rule is saved")
    end
  end

  test "the agents help page says it where it describes the rule" do
    text = read("lib/slipdock_web/live/help_live/agents.ex")
    assert text =~ about()
    assert_states(text, "a longer one is refused when the rule is saved")
  end

  test "no doc still gives a rule's prompt the whole cap" do
    refute read("docs/tool-packages.md") =~ "It is at most 20,000 bytes"
  end

  test "the served guide's runners section says it" do
    {:ok, section} = SlipdockWeb.APIGuide.section("runners", [])
    assert String.replace(section, ~r/\s+/, " ") =~ about()
  end
end
