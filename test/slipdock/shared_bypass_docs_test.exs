defmodule Slipdock.SharedBypassDocsTest do
  @moduledoc """
  A runner's warnings (#3482) are described where people and agents look:
  the guide and `docs/agents.md` name the `warnings` field and when it is
  given, and the manual's Machines page lists the warning among what a
  machine's page shows.
  """
  use ExUnit.Case, async: true

  import Slipdock.DocsFacts, only: [assert_states: 2]

  @root Path.expand("../..", __DIR__)
  defp read(path), do: Slipdock.DocsText.read!(Path.join(@root, path))

  test "the guide and docs/agents.md name the warnings and when they are given" do
    for text <- [SlipdockWeb.APIGuide.markdown(), read("docs/agents.md")] do
      assert_states(text, "Every runner in an answer carries `warnings`")
      assert_states(text, "`permission_mode` `bypassPermissions` under `executor` `me`")
      assert_states(text, "The daemon logs its own warning")
    end
  end

  test "the manual's Machines page lists the warning" do
    assert_states(
      read("docs/manual/machines.md"),
      "a **warning** on a runner that lets its agent run any command as you (permission mode `bypassPermissions` with the `me` executor)"
    )
  end
end
