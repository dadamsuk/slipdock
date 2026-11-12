defmodule Slipdock.HousekeepingDocsTest do
  @moduledoc """
  The Housekeeping list (#2777) is written up wherever a reader looks for
  the list categories: the README, the manual, the agents page, the in-app
  Flow help, the CLI's help and the loop skill.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)

  defp read(path), do: File.read!(Path.join(@root, path))

  test "each place names the list and says it comes after the ready list" do
    for {path, words} <- [
          {"README.md", "**Housekeeping** list (category `housekeeping`)"},
          {"docs/manual/recurring-cards.md", "**The Housekeeping list.**"},
          {"docs/agents.md", "A **Housekeeping** list (category `housekeeping`"},
          {"lib/slipdock_web/live/help_live/flow.ex", "<em>Work Housekeeping with a runner</em>"},
          {"cli/help.txt", "never the ready list), housekeeping"},
          {"priv/skills/slipdock-loop/SKILL.md",
           "A **Housekeeping** list (category `housekeeping`"}
        ] do
      assert read(path) =~ words, "#{path} doesn't say #{inspect(words)}"
    end
  end

  test "each place says a Housekeeping card that grows goes back to Triage (#2780)" do
    for {path, words} <- [
          {"docs/manual/recurring-cards.md", "move it to Triage, leave a *product*"},
          {"docs/agents.md", "goes back to a person: stop before building, move it to"},
          {"lib/slipdock_web/api_guide.ex",
           "**A Housekeeping card that grows goes back to a person.**"},
          {"lib/slipdock_web/live/help_live/flow.ex", "the agent moves it to Triage"},
          {"priv/skills/slipdock-loop/SKILL.md",
           "**A Housekeeping card that grows goes back to a person.**"}
        ] do
      assert read(path) =~ words, "#{path} doesn't say #{inspect(words)}"
    end
  end

  test "each place says the overseer writes a morning digest of it (#2781)" do
    for {path, words} <- [
          {"README.md", "digest of the Housekeeping list's overnight work"},
          {"docs/manual/the-overseer.md", "**The morning digest of Housekeeping's work.**"},
          {"lib/slipdock_web/api_guide.ex",
           "morning digest of\n    Housekeeping's work on its card (#2781)"},
          {"lib/slipdock_web/live/help_live/flow.ex", "digest of what Housekeeping worked"},
          {"cli/help.txt", "[--digest-at HH:MM]"},
          {"priv/skills/slipdock/SKILL.md", "--digest-at HH:MM"}
        ] do
      assert read(path) =~ words, "#{path} doesn't say #{inspect(words)}"
    end
  end
end
