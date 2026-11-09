defmodule SlipdockWeb.QualityDocsTest do
  @moduledoc """
  The quality numbers (#1796) as the docs describe them: the API guide's
  example, docs/agents.md, the README, the manual's Visualise section and its doors, and
  the CLI's help.
  """
  use SlipdockWeb.ConnCase, async: true

  @root Path.expand("../..", __DIR__)
  defp read(path), do: Slipdock.DocsText.read!(Path.join(@root, path))

  test "the API guide gives the endpoint and what it answers" do
    guide = SlipdockWeb.APIGuide.markdown()
    assert guide =~ ~s|B/api/boards/1/quality?days=30|
    assert guide =~ ~r/CLI: slipdock\s+#\s+quality\)/
    assert guide =~ "verified.first_time_right"
    assert guide =~ "per_100"
    assert guide =~ "by_rule (id, count, severity and page"
    assert guide =~ "slipdock quality --rules lists every rule"
  end

  test "docs/agents.md names the command and the endpoint" do
    agents = read("docs/agents.md")
    assert agents =~ "`slipdock quality <board> [--days N]`"
    assert agents =~ "`GET /api/boards/:id/quality?days=`"
    assert agents =~ "rejections by\npart and by rule id"
  end

  test "the manual describes the Visualise section and its doors" do
    manual = read("docs/manual.md")
    assert manual =~ "- **Quality** — how well agent work goes"
    assert manual =~ "**rework by area**"
    assert manual =~ "**rules most broken**"
    assert manual =~ "`slipdock quality <board> --rules` lists every rule"

    assert manual =~
             "`slipdock quality <board> [--days N]` and `GET /api/boards/:id/quality?days=`"
  end

  test "the README lists the quality numbers and their doors" do
    readme = read("README.md")
    assert readme =~ "- **Quality numbers** — [is the agent loop right first time?]"
    assert readme =~ "(docs/manual/visualise-flow-velocity-runners-and-delivery.md)"
    assert readme =~ "`slipdock quality <board> [--days N] [--rules]`"
    assert readme =~ "`GET /api/boards/:id/quality?days=`"
  end

  test "the CLI's help lists the command" do
    help = read("cli/help.txt")
    assert help =~ "quality <board> [--days N]"
    assert help =~ "--rules           every rule broken in the window"
  end
end
