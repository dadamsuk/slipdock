defmodule SlipdockWeb.AuditReworkDocsTest do
  @moduledoc """
  An audit that disagrees files the rework card itself (#2632): the manual's
  Verified work, the Flow help page, agents.md, the API guide, the skills an
  auditor reads and the CLI's help say so, and none still says a
  disagreement only alerts.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  @root Path.expand("../..", __DIR__)

  defp flat(text), do: String.replace(text, ~r/\s+/u, " ")
  defp read(path), do: @root |> Path.join(path) |> File.read!() |> flat()

  test "the manual, agents.md and the API guide say a disagreement files the rework" do
    manual = read("docs/manual/verified-work.md")
    assert manual =~ "so a disagreement files the rework itself"
    assert manual =~ "titled *Audit of #12: …* from the audit's reason"
    assert manual =~ "comments on it instead of making another"
    assert manual =~ "An audit that agrees files nothing"
    assert manual =~ "mutant survived or a `must` rule is broken"

    agents = read("docs/agents.md")
    assert agents =~ "A disagreement files the rework itself"
    assert agents =~ "`caused_by` the accepted card"
    assert agents =~ "comments on it rather than filing another"

    # The guide's Verified work text is written for a board that has it on.
    guide = read("lib/slipdock_web/api_guide.ex")
    assert guide =~ "Disagree also files the rework"
    assert guide =~ "a second disagreement comments on that card while it is open"

    for text <- [manual, agents, guide],
        do: refute(text =~ "disagree alerts the owner, and the acceptance stands")
  end

  test "the skills and the CLI's help an auditor reads say so" do
    assert read("priv/skills/slipdock-loop/SKILL.md") =~ "a rework card the server files"
    assert read("priv/skills/slipdock/SKILL.md") =~ "disagree alerts and files a rework card"
    assert read("cli/help.txt") =~ "and files a rework card, or comments on the open one"

    refute read("priv/skills/slipdock-loop/SKILL.md") =~
             "a disagreement is a comment and an alert for the board's owner."
  end

  test "the Flow help page says it", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/help/agents/flow")
    text = html |> LazyHTML.from_document() |> LazyHTML.text() |> flat()
    assert text =~ "a disagreement files the rework as a card in the ready list"
    assert text =~ "a second disagreement comments on it rather than filing another"
    assert text =~ "An audit that disagrees has already filed its rework card"
  end
end
