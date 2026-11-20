defmodule Slipdock.RunnerSteeringDocsTest do
  @moduledoc """
  Who steers a runner's agent (#3481) is said wherever a runner is set up:
  the manual's Machines page has the section, naming every executor and
  permission mode; the Runners page and the features in brief link to it;
  the guide and `docs/agents.md` name the add-runner answer's `notice`; and
  the notice itself (`Slipdock.Runners.Steering`) names every executor and
  permission mode the config allows, so a new one can't be left out of it.
  """
  use ExUnit.Case, async: true

  import Slipdock.DocsFacts, only: [assert_states: 2]

  alias Slipdock.Runners.{Config, Steering}

  @root Path.expand("../..", __DIR__)
  defp read(path), do: Slipdock.DocsText.read!(Path.join(@root, path))

  @claim "Anyone who can write or comment on a board a runner serves can steer its"

  test "the notice names every executor and permission mode" do
    for word <- Config.executors() ++ Config.permission_modes(),
        do: assert(Steering.notice() =~ "`#{word}`", "the notice leaves out #{word}")

    assert Steering.notice() =~ @claim
  end

  test "the manual's Machines page says it, naming every executor and mode" do
    text = read("docs/manual/machines.md")
    [_, section] = String.split(text, "### Who steers a runner's agent\n", parts: 2)
    [section | _] = String.split(section, "\n### ", parts: 2)

    assert String.replace(section, "\n", " ") =~ @claim

    for word <- Config.executors() ++ Config.permission_modes(),
        do: assert(section =~ "`#{word}`", "the manual's section leaves out #{word}")

    assert section =~ "slipdock machine add-runner"
  end

  test "the Runners page and the features in brief link to it" do
    for path <- ["docs/manual/runners.md", "docs/manual/every-feature-in-brief.md"],
        do: assert(read(path) =~ "machines.md#who-steers-a-runners-agent", path)
  end

  test "the guide and docs/agents.md name the add-runner answer's notice" do
    for text <- [SlipdockWeb.APIGuide.markdown(), read("docs/agents.md")],
        do: assert_states(text, "The `POST` answers with the `runner` and a `notice` (#3481)")
  end
end
