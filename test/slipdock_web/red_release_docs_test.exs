defmodule SlipdockWeb.RedReleaseDocsTest do
  @moduledoc """
  A red release holds nothing; it files its fix card (#2838, #3179), as the
  app's guide, the agents' flow help, the manual, docs/agents.md, the API
  guide, the CLI's help and the slipdock skill say it: Release now still
  releases, with a warning naming the failing run, and none of them names
  the hold's door any more (*Lift hold*, `--lift-hold`, `lift_hold`,
  `DELETE …/release/hold`).
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  @places [
    "docs/manual/every-feature-in-brief.md",
    "docs/manual/batched-releases.md",
    "docs/agents.md",
    "lib/slipdock_web/api_guide.ex",
    "cli/help.txt",
    "priv/skills/slipdock/SKILL.md"
  ]

  # Every place the hold was described (#2838), so none keeps its door.
  @swept @places ++
           [
             "README.md",
             "docs/manual.md",
             "lib/slipdock_web/live/help_live/guides/boards.html.heex",
             "lib/slipdock_web/live/help_live/flow/stages/claimed.html.heex",
             "lib/slipdock_web/live/help_live/agents/features.exs",
             "lib/slipdock_web/api_guide/deployments.md"
           ]

  defp read(path), do: Slipdock.DocsText.read!(Path.expand("../../" <> path, __DIR__))

  describe "the docs" do
    test "each says a red release holds nothing and Release now warns with the failing run",
         %{conn: conn} do
      claim =
        ~s(a red release "holds nothing": Release now still releases, with a warning naming the failing run)

      {:ok, _view, html} = live(conn, ~p"/help/boards")
      Slipdock.DocsFacts.assert_states(html, claim, "/help/boards")

      {:ok, _view, flow} = live(conn, ~p"/help/agents/flow")
      Slipdock.DocsFacts.assert_states(flow, claim, "/help/agents/flow")

      for path <- @places, do: Slipdock.DocsFacts.assert_states(read(path), claim, path)

      Slipdock.DocsFacts.assert_states(SlipdockWeb.APIGuide.markdown(), claim, "the API guide")
    end

    test "each says a fix card accepted with no code clears it and releases nothing (#2993)",
         %{conn: conn} do
      claim = ~s(the fix card "accepted with no code" clears it and releases nothing)

      {:ok, _view, html} = live(conn, ~p"/help/boards")
      Slipdock.DocsFacts.assert_states(html, claim, "/help/boards")

      # The agents' flow help, the page an agent working a fix card reads.
      {:ok, _view, flow} = live(conn, ~p"/help/agents/flow")
      Slipdock.DocsFacts.assert_states(flow, claim, "/help/agents/flow")

      for path <- @places, do: Slipdock.DocsFacts.assert_states(read(path), claim, path)
    end

    test "none names the hold or its door any more (#3179)", %{conn: conn} do
      gone = ~r/--lift-hold|lift_hold|release\/hold|Lift hold|holds releases|releases are held/

      for path <- @swept do
        refute read(path) =~ gone, "#{path} still describes the release hold"
      end

      for page <- [~p"/help/boards", ~p"/help/agents/flow", ~p"/help/agents"] do
        {:ok, _view, html} = live(conn, page)
        refute html =~ gone, "#{page} still describes the release hold"
      end

      refute SlipdockWeb.APIGuide.markdown() =~ gone
    end
  end
end
