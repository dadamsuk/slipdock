defmodule SlipdockWeb.ToolLinksDocsTest do
  @moduledoc """
  A Tool's skills and files over MCP without a token (#1158), as the docs
  describe it: the tool's description, the package reference, the manual,
  README, /help/agents and both copies of the slipdock skill.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  @root Path.expand("../..", __DIR__)
  defp read(path), do: File.read!(Path.join(@root, path))

  test "list_tools offers skill and link: true" do
    description = SlipdockWeb.MCP.Tools.ListTools.description()
    assert description =~ "With tool and skill: that skill's SKILL.md"
    assert description =~ "link: true instead returns a single-use download_url"
  end

  test "the package reference, the manual and README describe it" do
    assert read("docs/tool-packages.md") =~ "**Any of these without a token**"
    manual = read("docs/manual.md")
    assert manual =~ "and with `link: true` (#1158) a single-use `download_url`"
    assert manual =~ "With `skill`, that skill's `SKILL.md`, or with `file` a path in its folder."
    assert read("README.md") =~ "`link: true` gives a single-use download URL for a file"
  end

  test "the slipdock skill names both options" do
    assert read("priv/skills/slipdock/SKILL.md") =~
             "`skill` reads its `SKILL.md`; `link: true` gives a"
  end

  test "/help/agents mentions it", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/help/agents/skills")
    assert html =~ "for a shell with no API token"
  end
end
