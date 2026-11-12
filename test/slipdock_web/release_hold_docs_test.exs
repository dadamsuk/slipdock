defmodule SlipdockWeb.ReleaseHoldDocsTest do
  @moduledoc """
  A red release holds releases (#2838), as the app's guide, the README, the
  manual, docs/agents.md, the API guide, the CLI's help and the slipdock
  skill say it: what holds, and every door that lifts it.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  describe "the docs" do
    test "the guide, the help, the docs, the CLI help and the skill say a red release holds (#2838)",
         %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/help/boards")
      assert html =~ "A red release (its suite,"
      assert html =~ "<em>Lift hold</em>"

      read = &File.read!(Path.expand("../../" <> &1, __DIR__))

      for path <- [
            "README.md",
            "docs/manual/verified-work.md",
            "docs/agents.md",
            "lib/slipdock_web/api_guide.ex",
            "cli/help.txt",
            "priv/skills/slipdock/SKILL.md"
          ] do
        text = read.(path)
        assert text =~ "--lift-hold", "#{path} doesn't name --lift-hold"
        assert text =~ ~r/red release/i, "#{path} doesn't say a red release holds"
      end

      for path <- [
            "docs/manual/verified-work.md",
            "docs/agents.md",
            "lib/slipdock_web/api_guide.ex"
          ] do
        text = read.(path)
        assert text =~ "DELETE /api/boards/:board/release/hold", path
        assert text =~ "lift_hold: true", path
      end

      assert SlipdockWeb.APIGuide.markdown() =~ "A red release holds releases"
    end
  end
end
