defmodule SlipdockWeb.HandoffDocsTest do
  @moduledoc """
  Handoffs as the docs and skills describe them (W-1804): the guide says to
  read one first and leave one when stopping short, in the short guide an
  agent actually gets; the manual has the section the others link to; the
  help page and the slipdock-work and slipdock-loop skills say the same.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  @root Path.expand("../..", __DIR__)
  defp read(path), do: File.read!(Path.join(@root, path))

  test "the short guide says to read the handoff first and to leave one when stopping" do
    short = SlipdockWeb.APIGuide.short()
    assert short =~ "Read the card's `handoff` first"
    assert short =~ "Leave a handoff whenever you stop with the card unfinished"
    assert short =~ "POST  /api/cards/57/handoff"
  end

  test "the full guide documents the endpoint and the field" do
    guide = SlipdockWeb.APIGuide.markdown()
    assert guide =~ "**A handoff.** Where the card was left"
    assert guide =~ ~s("handoff": {"next_step")
    assert guide =~ "`leave_handoff` tool"
  end

  test "the manual has the section README and docs/agents.md link to" do
    manual = read("docs/manual.md")
    assert manual =~ ~r/^## Where it was left \(handoffs\)$/m
    assert manual =~ "POST   /api/cards/:id/handoff"
    assert manual =~ "slipdock handoff 12 --next"
    assert read("README.md") =~ "docs/manual.md#where-it-was-left-handoffs"
    assert read("docs/agents.md") =~ "manual.md#where-it-was-left-handoffs"
  end

  test "deleting a handoff is documented everywhere it is written (#1214)" do
    assert SlipdockWeb.APIGuide.markdown() =~
             "`DELETE /api/cards/:id/handoff` deletes the current one"

    manual = read("docs/manual.md")
    assert manual =~ "slipdock handoff 12 --delete"
    assert manual =~ "**Clear or delete.**"
    assert manual =~ "**Restore** makes an earlier one current again"
    assert manual =~ "**Label** replaces *Left off* wherever a person reads it"
    assert manual =~ "DELETE /api/cards/:id/handoff"
    assert read("README.md") =~ "`slipdock handoff 12 --delete`"
    assert read("priv/skills/slipdock/SKILL.md") =~ "slipdock handoff <id> --delete"
    assert SlipdockWeb.MCP.Tools.LeaveHandoff.description() =~ "delete: true deletes"
  end

  test "both skills read the handoff on claim and write one on stopping short" do
    work = read("priv/skills/slipdock-work/SKILL.md")
    assert work =~ "Read the handoff first, leave one when you stop short"
    assert work =~ ~s(slipdock handoff <id> --next)

    loop = read("priv/skills/slipdock-loop/SKILL.md")
    assert loop =~ "read it first and start there"
    assert loop =~ "**leave a handoff** before letting go"
    assert loop =~ "Never stop short on a card without leaving its handoff"
  end

  test "/help/agents has the handoff row and the runner note", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/help/agents")
    assert html =~ "Leave and read a card&#39;s handoff"

    {:ok, _view, html} = live(conn, ~p"/help/agents/runners")
    assert html =~ "leaves its summary as the card&#39;s"

    {:ok, _view, html} = live(conn, ~p"/help/agents/mcp")
    assert html =~ "leave_handoff"
  end
end
