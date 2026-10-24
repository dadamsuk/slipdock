defmodule SlipdockWeb.InboundDocsTest do
  @moduledoc """
  Emailing your board as the docs describe it (#1250): the manual's section
  and what links to it, the README, docs/agents.md, the API guide, the agents
  page, and both copies of the slipdock skill's commands.
  """
  use SlipdockWeb.ConnCase, async: true

  @root Path.expand("../..", __DIR__)
  defp read(path), do: File.read!(Path.join(@root, path))

  test "the manual has the section: addresses, what mail becomes, bounces, the log" do
    manual = read("docs/manual.md")
    assert manual =~ ~r/^## Emailing your board$/m
    assert manual =~ "[Emailing your board](#emailing-your-board)"
    assert manual =~ "[emailing\n  cards in](#emailing-your-board)"
    assert manual =~ "| `card-…@<domain>` |"
    assert manual =~ "| `add-…@<domain>` |"
    assert manual =~ "**What the message becomes.**"
    assert manual =~ "`[Board] Title`"
    assert manual =~ "**Why a message bounces.**"
    assert manual =~ "`card_limit_reached`"
    assert manual =~ "**Did it arrive?**"
    assert manual =~ "slipdock inbound me --ack on"
    assert manual =~ "W-1933"
  end

  test "the manual covers the page address: Inbox, [folder], + Title and its bounces" do
    manual = read("docs/manual.md")
    assert manual =~ "| `page-…@<domain>` |"
    assert manual =~ "**Mail to the page address**"
    assert manual =~ "`Inbox`"
    assert manual =~ "`[Design/Decisions] Use Postgres`"
    assert manual =~ "**`+ Title` adds to a page instead**"
    assert manual =~ "for `+ Title`: there is no page of that title"
    assert manual =~ "`Slipdock.Inbound.Pages`"
  end

  test "README links to it from the features and from Receiving email" do
    readme = read("README.md")
    assert readme =~ "**Email a card in**"
    assert Regex.scan(~r/docs\/manual\.md#emailing-your-board/, readme) |> length() >= 2
    assert readme =~ "slipdock inbound\n<board>`"
    assert readme =~ "(W-1933)"
    assert readme =~ "`page-…@` address"
    assert readme =~ "`+ Title` adds a dated section"
  end

  test "docs/agents.md says where to look when mail didn't arrive" do
    agents = read("docs/agents.md")
    assert agents =~ "emailed a card or a page in and nothing happened"
    assert agents =~ "manual.md#emailing-your-board"
    assert agents =~ "A `+ Title` mail bounces when no page has that title"
  end

  test "the API guide and the agents page name the endpoints" do
    guide = SlipdockWeb.APIGuide.markdown()
    assert guide =~ "`GET /api/boards/:board/inbound`"
    assert guide =~ "`POST /api/me/inbound {\"ack\": true}`"

    page = read("lib/slipdock_web/live/help_live/agents.ex")
    assert page =~ "GET /api/boards/:id/inbound, /api/me/inbound"
    assert page =~ "slipdock inbound <board>, inbound me"
  end

  test "both copies of the slipdock skill list the inbound commands" do
    installed = Path.expand("~/.claude/skills/slipdock/SKILL.md")

    for path <- [Path.join(@root, "priv/skills/slipdock/SKILL.md"), installed],
        File.exists?(path) do
      skill = File.read!(path)
      assert skill =~ "slipdock inbound <board> [--rotate]"
      assert skill =~ ~s("+ Title" appends a dated section)
      assert skill =~ "slipdock inbound me [--rotate] [--ack on|off]"
      assert skill =~ "slipdock inbound log"
    end
  end
end
