defmodule SlipdockWeb.GardenDocsTest do
  @moduledoc """
  The board gardener as the docs describe it (W-1807): the guide's recipe
  and MCP tool list, the manual's Tidying up section the others link to
  (every check named, the folder rule the tuning added), README,
  docs/agents.md, /help and /help/agents, and the slipdock and
  slipdock-work skills.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  @root Path.expand("../..", __DIR__)
  defp read(path), do: File.read!(Path.join(@root, path))

  test "the guide has the recipe; the short guide's tool list names garden and garden_decide" do
    guide = SlipdockWeb.APIGuide.markdown()
    assert guide =~ "**Tidying up a board.** The gardener (W-1807)"
    assert guide =~ "`POST /api/garden/suggestions/:id/apply`"
    assert guide =~ ~r/apply only what they approve; never\s+dismiss one on your own/

    assert SlipdockWeb.APIGuide.short() =~
             ~r/`garden` and\s+`garden_decide` \(tidy-up suggestions\)/
  end

  test "the manual has the section, every check, the commands and the endpoints" do
    manual = read("docs/manual.md")
    assert manual =~ ~r/^## Tidying up$/m
    assert manual =~ "[Tidying up](#tidying-up)"

    for check <- Slipdock.Gardener.checks() do
      assert manual =~ "| #{check.label()} |", "the manual's table lacks #{check.label()}"
    end

    assert manual =~ "no backlink, no pin and no folder"
    assert manual =~ "slipdock garden apply 43 --keep 12"
    assert manual =~ "POST  /api/garden/suggestions/:id/apply {keep?, choice?}"
    assert manual =~ "**Weekly tidy-up**"
    assert manual =~ "A dismissal stays dismissed"
  end

  test "README and docs/agents.md link to it" do
    assert read("README.md") =~ "docs/manual.md#tidying-up"
    agents = read("docs/agents.md")
    assert agents =~ "manual.md#tidying-up"
    assert agents =~ ~r/apply only what they\s+approve; never dismiss one on your own judgment/
  end

  test "both copies of the skills have it: the commands, and apply only what is approved" do
    skill = read("priv/skills/slipdock/SKILL.md")
    assert skill =~ "slipdock garden <board> [--run] [--check K]"
    assert skill =~ "slipdock garden apply <id>... [--keep CARD] [--choice NAME]"
    assert skill =~ "apply only the ones they say yes to"

    work = read("priv/skills/slipdock-work/SKILL.md")
    assert work =~ "**Tidy-up suggestions are the person's to decide.**"
    assert work =~ "never apply or dismiss"
  end

  test "/help and /help/agents describe it", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/help/boards")
    assert html =~ "<strong>Tidy up…</strong>"

    {:ok, _view, html} = live(conn, ~p"/help/automations")
    assert html =~ "Weekly tidy-up"

    {:ok, _view, html} = live(conn, ~p"/help/agents")
    assert html =~ "Tidy a board up: see what the gardener found, apply or dismiss"

    {:ok, _view, html} = live(conn, ~p"/help/agents/mcp")
    assert html =~ "garden_decide"
  end
end
