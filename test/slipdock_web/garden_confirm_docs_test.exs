defmodule SlipdockWeb.GardenConfirmDocsTest do
  @moduledoc """
  `slipdock garden apply|dismiss|undo <id> --confirm` (#2638, documented on
  #2648), said wherever a person or an agent looks for it: the API guide, the
  agents page, the manual's Tidying up page, HelpLive.Agents and the slipdock
  skill (`priv/skills`, the one source). Each says a person deciding a
  proposal from Claude Code adds `--confirm`, and that a runner job's confirm
  is refused.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)

  defp read(path), do: Slipdock.DocsText.read!(Path.join(@root, path))
  defp flat(text), do: String.replace(text, ~r/\s+/, " ")

  test "the API guide gives --confirm and confirm: true, and refuses a runner job's" do
    guide = flat(read("lib/slipdock_web/api_guide.ex"))

    assert guide =~ "`…/dismiss` and `…/undo` decide one (each takes `confirm: true`"

    assert guide =~
             "a person deciding a proposal from Claude Code adds `--confirm` " <>
               "(`slipdock garden apply|dismiss|undo <id> --confirm`, REST `confirm: true`)"

    assert guide =~ "A runner job's confirm is refused, and so is a bare script token's"
  end

  test "docs/agents.md says the person adds --confirm, and a runner job's is refused" do
    agents = flat(read("docs/agents.md"))

    assert agents =~
             "a person deciding a proposal from Claude Code adds `--confirm` " <>
               "(`slipdock garden apply 41 --confirm`, REST `confirm: true`)"

    assert agents =~ "A runner job's confirm is refused"
  end

  test "the manual's Tidying up page gives --confirm in the CLI, REST and prose" do
    page = read("docs/manual/tidying-up.md")

    assert page =~ ~r/^slipdock garden apply 45 --confirm\s+# a proposal, decided by you/m
    assert page =~ "POST  /api/garden/suggestions/:id/apply {keep?, choice?, confirm?}"
    assert page =~ "POST  /api/garden/suggestions/:id/dismiss {confirm?}"
    assert page =~ "POST  /api/garden/suggestions/:id/undo {confirm?}"

    flat = flat(page)
    assert flat =~ "when you decide a proposal from Claude Code, add `--confirm`"
    assert flat =~ "A runner job's confirm is refused"
  end

  test "HelpLive.Agents says it beside garden_decide" do
    help = flat(read("lib/slipdock_web/live/help_live/agents.ex"))

    assert help =~
             "from Claude Code a person deciding a proposed handbook edit adds " <>
               "<code>--confirm</code>, <code>slipdock garden apply &lt;id&gt; --confirm</code>, " <>
               "and a runner job's confirm is refused"
  end

  test "the slipdock skill lists --confirm and says when to use it" do
    skill = read("priv/skills/slipdock/SKILL.md")

    assert skill =~
             ~r/^slipdock garden apply\|dismiss\|undo <id> --confirm\s+# a proposal, decided by the person from Claude Code/m

    flat = flat(skill)
    assert flat =~ "(their say-so; a runner job's confirm is refused)"
    assert flat =~ "when they decide one from Claude Code, add `--confirm`"
    assert flat =~ "A runner job's confirm is refused, so in a runner job leave a proposal"
  end
end
