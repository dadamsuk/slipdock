defmodule SlipdockWeb.GardenConfirmDocsTest do
  @moduledoc """
  A proposal is decided on the board's Tidy-up page (W-1945 §Permissions,
  #2668), said wherever a person or an agent looks for it (#2688): the API
  guide, the agents page, the manual's Tidying up page, HelpLive.Agents and
  the slipdock skill (`priv/skills`, the one source). Each says so in place
  of `slipdock garden apply|dismiss|undo <id> --confirm`, which #2638 had
  them give and #2668 closed.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)

  defp read(path), do: Slipdock.DocsText.read!(Path.join(@root, path))
  defp flat(text), do: String.replace(text, ~r/\s+/, " ")

  test "the API guide sends a proposal to the Tidy-up page, whatever confirm says" do
    guide = flat(read("lib/slipdock_web/api_guide.ex"))

    assert guide =~ "`…/dismiss` and `…/undo` decide one (a proposal excepted: see below)"

    assert guide =~
             "a proposal is decided on the board's Tidy-up page (`/boards/<id>/tidy`, " <>
               "which shows the section's diff), signed in, and nowhere else " <>
               "(W-1945 §Permissions, #2668)"

    assert guide =~ "whatever token, headers or `confirm` they send"

    assert guide =~
             "a person decides each on the board's Tidy-up page, which `slipdock findings` links"

    refute guide =~ "--confirm"
  end

  test "docs/agents.md says a proposal is decided on the Tidy-up page" do
    agents = flat(read("docs/agents.md"))

    assert agents =~
             "a proposal is decided on the board's Tidy-up page (`/boards/<id>/tidy`), " <>
               "signed in, and nowhere else (W-1945 §Permissions, #2668)"

    assert agents =~ "Point the person at the page."
    refute agents =~ "--confirm"
  end

  test "the manual's Tidying up page gives the Tidy-up page, and no confirm in the CLI or REST" do
    page = read("docs/manual/tidying-up.md")

    refute page =~ "--confirm"
    refute page =~ "confirm?"
    assert page =~ "POST  /api/garden/suggestions/:id/apply {keep?, choice?}\n"
    assert page =~ "POST  /api/garden/suggestions/:id/dismiss\n"
    assert page =~ "POST  /api/garden/suggestions/:id/undo\n"

    flat = flat(page)
    assert flat =~ "**A proposal is decided on the Tidy-up page.**"
    assert flat =~ "it is decided on the board's Tidy-up page (`/boards/<id>/tidy`), signed in"
    assert flat =~ "The CLI, REST and MCP are refused with the page's link"
  end

  test "HelpLive.Agents says it beside garden_decide" do
    help = flat(read("lib/slipdock_web/live/help_live/agents.ex"))

    assert help =~
             "a proposed handbook edit is decided only on the board's Tidy-up page, " <>
               "signed in, and <code>garden_decide</code> and the CLI are refused with its link"

    refute help =~ "--confirm"
  end

  test "the slipdock skill sends the person to the Tidy-up page" do
    skill = read("priv/skills/slipdock/SKILL.md")

    assert skill =~
             ~r/^\s+# a proposal: the person decides it on the board's Tidy-up\n\s+# page \(the listing links it\); the CLI is refused \(#2668\)$/m

    flat = flat(skill)
    assert flat =~ "(decided on the board's Tidy-up # page, which it links)"

    assert flat =~
             "a proposal is decided on the board's Tidy-up page (`/boards/<id>/tidy`, signed in)"

    assert flat =~ "give the person that link and leave the proposal to them"
    refute skill =~ ~r/garden \S+ \S+ --confirm/
  end
end
