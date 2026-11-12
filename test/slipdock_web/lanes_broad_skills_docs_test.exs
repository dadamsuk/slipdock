defmodule SlipdockWeb.LanesBroadSkillsDocsTest do
  @moduledoc """
  The skills say what a broad lane glob is (#2701, after #2698): a `**` at
  most one directory below the repository root, unless wholly inside a
  shared path; that it is advice, not a refusal; and that a glob marked
  broad in the job prompt's Paths block (or `paths_broad`) is narrowed
  before starting.
  """
  use ExUnit.Case, async: true

  import Slipdock.DocsFacts, only: [assert_states: 2, states?: 2]

  @root Path.expand("../..", __DIR__)
  defp read(path), do: Slipdock.DocsText.read!(Path.join(@root, path))

  # Shared by both skills. The definition itself (the `**` and how far below
  # the root) is worded differently in each, so each test checks its own.
  @parts [
    "unless wholly inside a shared path",
    "advice, not a refusal",
    "a glob marked broad in the job prompt's Paths block",
    "(or listed in `paths_broad` in `get_card`",
    "is narrowed before starting"
  ]

  test "the loop skill's Lanes section says what broad is and that it is narrowed first" do
    [_, lanes] = String.split(read("priv/skills/slipdock-loop/SKILL.md"), "\n## Lanes\n")
    [lanes | _] = String.split(lanes, "\n## ")

    assert_states(
      lanes,
      "Keep them as narrow as the brief allows. A glob is *broad* when it ends in `**` and " <>
        "sits at most one directory below the repository root"
    )

    assert_states(lanes, "`paths_broad` in `get_card` and `slipdock card`)")
    for part <- ["wholly inside a shared path" | @parts], do: assert_states(lanes, part)
  end

  test "the work skill's paths step says the same" do
    work = read("priv/skills/slipdock-work/SKILL.md")
    [_, step] = String.split(work, "- **Lanes, where they are on**")
    [step | _] = String.split(step, "\n- **")
    assert_states(step, "as narrow as the brief allows.")
    assert_states(step, "A glob ending in `**` at most one directory below the repository root")
    assert_states(step, "is *broad*")
    for part <- @parts, do: assert_states(step, part)
  end

  test "a fact not in the skill is not found, so the checks above can fail" do
    work = read("priv/skills/slipdock-work/SKILL.md")
    refute states?(work, "a glob marked broad in `paths_wide` is narrowed before starting")
    refute states?(work, "Keep them as narrow as the brief allows: a `***` glob is broad")
  end
end
