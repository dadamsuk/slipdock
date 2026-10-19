defmodule SlipdockWeb.TransferLinksDocsTest do
  @moduledoc """
  Upload and download links (#1147) as the docs describe them: the guide,
  the tools' descriptions, the manual's MCP table, README, docs/agents.md,
  /help/agents and both copies of the slipdock skill.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  @root Path.expand("../..", __DIR__)
  defp read(path), do: File.read!(Path.join(@root, path))

  test "the guide names the option and both endpoints" do
    guide = SlipdockWeb.APIGuide.markdown()
    assert guide =~ "`/api/upload/:secret` or `/api/download/:secret`"
    assert SlipdockWeb.APIGuide.short() =~ "a shell: `link: true`"
  end

  test "the tools' descriptions offer it" do
    assert SlipdockWeb.MCP.Tools.UploadFile.description() =~ "link: true"
    assert SlipdockWeb.MCP.Tools.DownloadFile.description() =~ "link: true"
  end

  test "the manual, README and docs/agents.md describe it" do
    manual = read("docs/manual.md")
    assert manual =~ "`upload_url` that works once, for 10 minutes, with no token"
    assert manual =~ "`download_url` that works once, for 10 minutes, with no token"
    assert manual =~ "`410 link_gone`"

    assert read("README.md") =~ "a single-use upload URL, good for ten minutes"
    assert read("docs/agents.md") =~ "`curl -F file=@cv.docx -F sha256=<hex> <upload_url>`"
  end

  test "the slipdock skill sends a caller with a shell to it" do
    skill = read("priv/skills/slipdock/SKILL.md")
    assert skill =~ "`upload_file` with `card`/`page` and `link: true` (#1147)"
    assert skill =~ "`curl -fsSo FILE <download_url>`"
  end

  test "/help/agents mentions it", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/help/agents/mcp")
    assert html =~ "gives a single-use URL"
  end
end
