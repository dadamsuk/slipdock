defmodule SlipdockWeb.HandbookDocsTest do
  @moduledoc """
  The handbook as the docs describe it (#1265): the guide's section and the
  line in *Working a card*, the manual, README, the agents page, the CLI's
  help and the slipdock skill.
  """
  use SlipdockWeb.ConnCase, async: true

  import Slipdock.DocsFacts, only: [assert_states: 2]

  @root Path.expand("../..", __DIR__)
  defp read(path), do: Slipdock.DocsText.read!(Path.join(@root, path))

  test "the guide has the handbook section, and the short guide points at it" do
    guide = SlipdockWeb.APIGuide.markdown()
    assert guide =~ "## The handbook"
    assert guide =~ "slipdock tools install-board handbook --board <board>"
    assert guide =~ "GET /api/boards/:board/handbook"
    assert guide =~ "`Handbook: updated W-3 §Contexts, new W-41`"
    assert guide =~ "`Handbook: no change (<why>)`"

    # The short guide is at its cap: it carries the section's index line.
    assert SlipdockWeb.APIGuide.short() =~ "`handbook` — The handbook"
  end

  test "the manual documents install, the card key and the commands" do
    manual = read("docs/manual.md")
    assert_states(manual, "**The handbook** is the one built-in Tool")
    assert manual =~ "`slipdock tools install-board handbook --board B`"
    assert manual =~ "`handbook` key"
    assert manual =~ "`slipdock handbook <board>`"
    assert manual =~ ~r/\| `get_card` \|[^\n]*`handbook`/
    assert manual =~ ~r/\| `install_tool` \|[^\n]*`tool: "handbook"` with `board`/
  end

  test "README, the CLI help and the skill name the commands" do
    # The bullet is in the manual's digest; the README keeps a line (#2792).
    assert_states(
      read("docs/manual/every-feature-in-brief.md"),
      "**The handbook.** One Tool is built in"
    )

    assert_states(read("README.md"), "One Tool is built in")
    help = read("cli/help.txt")
    assert help =~ "tools install-board handbook --board B"
    assert help =~ "handbook <board>|<card>"

    skill = read("priv/skills/slipdock/SKILL.md")
    assert skill =~ "slipdock tools install-board handbook --board B"
    assert skill =~ "slipdock handbook <card>"
  end

  test "the gardener's check is in the guide's recipe and the manual's table" do
    assert_states(
      SlipdockWeb.APIGuide.markdown(),
      "cards closed on a handbook board without a `Handbook:` line"
    )

    assert read("docs/manual.md") =~ "| Closed without a Handbook line |"
  end

  # Read over HTTP, not through `live/2`: the test only reads what the page
  # says, and a join the channel refuses (this host's clock stepping back under
  # load, W-1950 §Tests, #2732) came back from `live/2` as a redirect to the
  # page itself (#2870).
  test "the agents page explains it", %{conn: conn} do
    html = conn |> get(~p"/help/agents/skills") |> html_response(200)
    assert html =~ "The handbook"
    assert html =~ "line in its closing comment"
  end
end
