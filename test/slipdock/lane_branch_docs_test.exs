defmodule Slipdock.LaneBranchDocsTest do
  @moduledoc """
  A runner's lane branch starts from the origin's default branch as fetched
  at the job's start, also when a `card-<id>` branch is already there
  (#3002: #2994's lane sat on a local branch made before #2984's fix
  merged, and its agent wrote the same fix again). The daemon's behaviour is
  tested in `daemon/internal/runner/worker_test.go`; the manual says it, and
  the loop skill tells a bug or flaky-test card to look at what the default
  branch has done to the named file since the failure before reproducing it.
  """
  use ExUnit.Case, async: true

  import Slipdock.DocsFacts, only: [assert_states: 2]

  @root Path.expand("../..", __DIR__)
  defp flat(path),
    do: @root |> Path.join(path) |> Slipdock.DocsText.read!() |> String.replace(~r/\s+/, " ")

  test "the manual says a card branch already there catches up with the default branch" do
    manual = flat("docs/manual/machines.md")
    assert_states(manual, "A card branch already there catches up with it")
    assert_states(manual, "one with nothing of its own is moved up to it")
    assert_states(manual, "has them rebased onto it")
    assert_states(manual, "If that rebase conflicts, it is undone, the branch is left as it was")
    refute manual =~ "a branch already there (a rejected card's) is used as it is"
  end

  test "the loop skill checks for a later fix before reproducing a bug" do
    core = flat("priv/skills/slipdock-loop/SKILL.md")
    assert_states(core, "A flaky-test card is a bug card")

    assert_states(
      core,
      "checks first whether the default branch has changed the named file or path since the reported failure, reading that change before reproducing"
    )

    loop = flat("priv/skills/slipdock-loop/references/bugs.md")
    assert_states(loop, "**First, has it been fixed since?**")
    assert_states(loop, "origin/<default-branch> -- <the file or path>")
    assert_states(loop, "A commit there may already be the fix (another card's): read it first")
  end
end
