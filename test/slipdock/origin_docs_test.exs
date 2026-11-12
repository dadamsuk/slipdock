defmodule Slipdock.OriginDocsTest do
  @moduledoc """
  Origin on cards (#2778) is written up wherever a reader looks for a
  card's fields and filters: the README, the manual, the agents page, the
  API guide, the in-app help, the CLI's help and the slipdock skill.
  """
  use ExUnit.Case, async: true

  import Slipdock.DocsFacts, only: [assert_states: 3]

  @root Path.expand("../..", __DIR__)

  defp read(path), do: File.read!(Path.join(@root, path))

  test "each place says where a card came from, and that a job may name only a generator" do
    for {path, words} <- [
          {"README.md", "**Every card says where it came from.**"},
          {"docs/manual/flow-the-pulse-a-cards-state-and-its-age.md", "**Where it came from.**"},
          {"docs/agents.md", "`sweep` or `findings` only"},
          {"lib/slipdock_web/api_guide.ex", "**Where a card came from** (#2778)"},
          {"lib/slipdock_web/live/help_live/agents.ex",
           "<strong>Where a card came from.</strong>"},
          {"lib/slipdock_web/live/help_live/guides.ex", "due date and origin"},
          {"cli/help.txt", "--origin sweep|findings"},
          {"priv/skills/slipdock/SKILL.md", "--origin sweep|findings names the generator"}
        ] do
      assert_states(read(path), words, "#{path} doesn't say #{inspect(words)}")
    end
  end
end
