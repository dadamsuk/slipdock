defmodule SlipdockWeb.ToolLinksDocsTest do
  @moduledoc """
  A Tool's skills and files over MCP without a token (#1158), as the docs
  describe it: the tool's description, the package reference, the manual,
  README, /help/agents and both copies of the slipdock skill.
  """
  use SlipdockWeb.ConnCase, async: true

  import Slipdock.DocsFacts, only: [assert_states: 2]

  import Phoenix.LiveViewTest

  @root Path.expand("../..", __DIR__)
  defp read(path), do: Slipdock.DocsText.read!(Path.join(@root, path))

  test "list_tools offers skill and link: true" do
    description = SlipdockWeb.MCP.Tools.ListTools.description()
    assert_states(description, "With tool and skill: that skill's SKILL.md")
    assert description =~ "link: true instead returns a single-use download_url"
  end

  test "the package reference, the manual and the feature digest describe it" do
    assert_states(read("docs/tool-packages.md"), "**Any of these without a token**")
    manual = read("docs/manual.md")
    assert manual =~ "and with `link: true` (#1158) a single-use `download_url`"

    assert_states(
      manual,
      "With `skill`, that skill's `SKILL.md`, or with `file` a path in its folder."
    )

    assert_states(
      read("docs/manual/every-feature-in-brief.md"),
      "`link: true` gives a single-use download URL for a file"
    )
  end

  test "the slipdock skill names both options" do
    assert read("priv/skills/slipdock/SKILL.md") =~
             "`skill` reads its `SKILL.md`; `link: true` gives a"
  end

  test "/help/agents mentions it", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/help/agents/skills")
    assert_states(html, "for a shell with no API token")
    assert html =~ "links the whole package instead"
  end

  test "the manual, the package reference and the feature digest say a package can be uploaded" do
    for path <- ~w(docs/tool-packages.md docs/manual.md docs/manual/every-feature-in-brief.md) do
      assert read(path) =~ "**Publish a Tool**", path
    end
  end

  describe "the whole package" do
    test "list_tools offers package: true" do
      assert_states(
        SlipdockWeb.MCP.Tools.ListTools.description(),
        "package: true links the whole package"
      )

      assert SlipdockWeb.MCP.Tools.ListTools.input_schema().properties.package.type == "boolean"
    end

    test "the package reference, the manual and the feature digest give the endpoint and the CLI" do
      for path <- ~w(docs/tool-packages.md docs/manual.md docs/manual/every-feature-in-brief.md) do
        text = read(path)
        assert text =~ "/api/tools/<name>/package.tar.gz", path
        assert text =~ "slipdock tools download", path
      end

      assert read("docs/tool-packages.md") =~
               ~s("package": "/api/tools/reply-drafts/package.tar.gz?version=1.0.0")
    end

    test "the slipdock skill names the command and the option" do
      skill = read("priv/skills/slipdock/SKILL.md")
      assert skill =~ "slipdock tools download <name> [--version V] [--out F|-] [--force]"
      assert skill =~ "`package: true`"
    end
  end
end
