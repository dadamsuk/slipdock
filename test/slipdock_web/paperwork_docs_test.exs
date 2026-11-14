defmodule SlipdockWeb.PaperworkDocsTest do
  @moduledoc """
  Paperwork is noted, not rejected (#3182): every place that tells people
  and agents how a verdict is decided says so. That is the manual's Verified
  work, `docs/agents.md`, the API guide, the in-app flow help, the loop
  skill's verifying reference, the slipdock skill, the CLI help and the MCP
  `verify_card` tool's `checks`.
  """
  use ExUnit.Case, async: true

  import Slipdock.DocsFacts, only: [assert_states: 2]

  alias SlipdockWeb.MCP.Tools.VerifyCard

  @root Path.expand("../..", __DIR__)

  defp flat(path), do: @root |> Path.join(path) |> Slipdock.DocsText.read!() |> squash()
  defp squash(text), do: String.replace(text, ~r/[\s#]+/, " ")

  test "the manual and agents.md say paperwork alone accepts, anything else rejects" do
    for path <- ["docs/manual/verified-work.md", "docs/agents.md"] do
      doc = flat(path)
      assert_states(doc, "`evidence=disputed` paperwork noted, not rejected")
      assert_states(doc, "paperwork fails: verdict accepts, rejection")
      assert_states(doc, "other failing part still rejects; person's rejection stands")
    end
  end

  test "the API guide, the flow help and the skills say it" do
    assert_states(
      flat("lib/slipdock_web/api_guide/verified_verify.md"),
      "`evidence=ok|disputed` paperwork finding accepts"
    )

    assert_states(
      flat("lib/slipdock_web/live/help_live/flow/stages/verifying.html.heex"),
      "Paperwork noted finding, not rejected: accepted"
    )

    loop = flat("priv/skills/slipdock-loop/references/verifying.md")
    assert_states(loop, "`--check evidence=disputed:<why>` paperwork noted, not rejected")
    assert_states(loop, "every other failing part still rejects")

    assert_states(
      flat("priv/skills/slipdock/SKILL.md"),
      "evidence=ok|disputed paperwork: finding, alone accepts"
    )
  end

  test "the CLI help and the MCP tool name the evidence part and say it accepts" do
    assert_states(flat("cli/help.txt"), "evidence=ok|disputed paperwork finding accepts")

    assert_states(
      squash(VerifyCard.input_schema().properties.checks.description),
      "evidence=ok|disputed paperwork finding accepts"
    )
  end
end
