defmodule SlipdockWeb.HelpLive.TemplatesTest do
  @moduledoc """
  The help pages' words are templates beside their modules (#2919): a guide
  per section under `help_live/guides/`, a page per way in under
  `help_live/agents/topics/`, a stage per stage under `help_live/flow/stages/`.
  The module dispatches on its data (`Guides.sections/0`, `Agents.topics/0`,
  `Flow.stages/0`), so a section without a template doesn't compile; this
  holds the other direction, that no template sits there unread, and that
  the docs tests reading a help page's module read its templates too.
  """
  use ExUnit.Case, async: true

  alias SlipdockWeb.HelpLive.{Agents, Flow, Guides}

  @help Path.expand("../../../../lib/slipdock_web/live/help_live", __DIR__)

  defp templates(dir) do
    @help
    |> Path.join(dir <> "/*.html.heex")
    |> Path.wildcard()
    |> Enum.map(&(&1 |> Path.basename() |> String.replace_suffix(".html.heex", "")))
    |> Enum.sort()
  end

  test "each guide's template is a section's, and each section has one" do
    assert templates("guides") == Enum.sort(Guides.slugs())
  end

  test "each way in's template is a topic's, and each topic has one" do
    assert templates("agents/topics") == Enum.sort(Agents.slugs())
    assert templates("agents") == ["overview"]
  end

  test "each stage's template is a stage's, and each stage has one" do
    assert templates("flow/stages") == Enum.sort(Enum.map(Flow.stages(), & &1.id))
    assert templates("flow") == ["flow_page"]
  end

  test "a help page's module reads, for the docs tests, as the module and its templates" do
    for name <- ~w(guides agents flow) do
      text = Slipdock.DocsText.read!(Path.join(@help, name <> ".ex"))
      parts = Slipdock.DocsText.help_parts(name)

      assert parts != []
      assert text =~ "defmodule SlipdockWeb.HelpLive."

      for part <- parts, do: assert(text =~ File.read!(part), part)
    end

    # Named, not taken from help_parts/1 itself: a template in a
    # subdirectory and a data file are among the parts read.
    for {name, part} <- [
          {"flow", "flow/stages/verifying.html.heex"},
          {"flow", "flow/settings.exs"},
          {"agents", "agents/topics/cli.html.heex"},
          {"agents", "agents/features.exs"},
          {"guides", "guides/sections.exs"},
          {"guides", "guides/boards.html.heex"}
        ] do
      path = Path.join(@help, part)
      assert path in Slipdock.DocsText.help_parts(name), part
      assert Slipdock.DocsText.read!(Path.join(@help, name <> ".ex")) =~ File.read!(path), part
    end

    assert Slipdock.DocsText.read!(Path.join(@help, "index.ex")) ==
             File.read!(Path.join(@help, "index.ex"))
  end
end
