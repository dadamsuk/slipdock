defmodule SlipdockWeb.AuditMissesDocsTest do
  @moduledoc """
  The verify prompt's recent audit misses (#2695), as the manual's Verified
  work page, `docs/agents.md`, the API guide, the loop skill, the agents
  help and the Flow page say it: the last five of the
  last 30 days, checked first, kept after the rework is done, and never in
  the audit prompt.
  """
  use SlipdockWeb.ConnCase, async: true

  import Slipdock.DocsFacts, only: [assert_states: 2]

  import Phoenix.LiveViewTest

  @root Path.expand("../..", __DIR__)

  defp flat(text), do: String.replace(text, ~r/\s+/u, " ")

  test "the manual's audit bullet says the verify prompt carries recent misses" do
    manual = @root |> Path.join("docs/manual/verified-work.md") |> File.read!() |> flat()

    assert_states(manual, "the verify prompt carries *What audits on this board caught recently*")
    assert_states(manual, "the last five audit disagreements of the last 30 days")
    assert_states(manual, "tells the verifier to check those first")
    assert_states(manual, "the audit prompt never carries it")
  end

  test "docs/agents.md, the API guide and the loop skill say it" do
    read = fn path -> @root |> Path.join(path) |> Slipdock.DocsText.read!() |> flat() end

    agents = read.("docs/agents.md")
    assert_states(agents, "the verify prompt carries *What audits on this board caught recently*")
    assert_states(agents, "for the verifier to check first")
    assert_states(agents, "The audit prompt never carries it.")

    guide = read.("lib/slipdock_web/api_guide.ex")

    assert_states(
      guide,
      "The verify prompt (never the audit's) lists the tree's last five audit misses"
    )

    skill = read.("priv/skills/slipdock-loop/SKILL.md")
    assert_states(skill, "*What audits on this board caught recently*): check those first")
    assert skill =~ "An audit's prompt never does"
  end

  test "the agents help says it", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/help/agents/skills")

    text =
      html
      |> LazyHTML.from_document()
      |> LazyHTML.query("#help-audit-misses")
      |> LazyHTML.text()
      |> flat()

    assert_states(text, "what audits on this board caught recently")
    assert_states(text, "the last five audit disagreements of the last 30 days")
    assert text =~ "check those first"
    assert_states(text, "The audit's own prompt never carries the list")
  end

  test "the Flow help page's audit item says it", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/help/agents/flow")
    text = html |> LazyHTML.from_document() |> LazyHTML.text() |> flat()

    assert_states(text, "The verify prompt then lists the board's last five audit misses")
    assert text =~ "the audit prompt never does"
  end
end
