defmodule SlipdockWeb.VerifyByCiDocsTest do
  @moduledoc """
  On a board that ships by pull request the PR's CI is the one full test
  run (#1808): the builder runs only its own tests before pushing, and the
  verifier checks the PR's checks at the submitted commit rather than
  running the suite again. Every place the procedure is written says so.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)
  defp read(path), do: File.read!(Path.join(@root, path))

  test "the loop skill: the builder's tests, and the verifier's CI check" do
    loop = read("priv/skills/slipdock-loop/SKILL.md")

    assert loop =~
             "It is the full\n  test run: before pushing, run only the tests you added or changed"

    assert loop =~ "never the whole suite as well, and complete\n  the card once the checks pass."
    assert loop =~ "On a board that ships by pull request, don't run the suite: its\n  CI ran it"
    assert loop =~ "run the suite only if it has no checks."
  end

  test "the work and CLI skills" do
    work = read("priv/skills/slipdock-work/SKILL.md")
    assert work =~ "(on a pull\n  request board, checking its CI passed at that commit instead)"

    assert work =~
             "(the full test run: before pushing, run only the tests you\n  added or changed)"

    assert read("priv/skills/slipdock/SKILL.md") =~
             "# its CI is the full test run: run only your own tests before"
  end

  test "the API guide, the manual, the agents page and CLAUDE.md" do
    guide = read("lib/slipdock_web/api_guide.ex")
    assert guide =~ "pull request's, and it is the full test run"

    assert guide =~
             "A verifier doesn't run the suite again either: it\n    reads the change and checks that the pull request's head"

    manual = read("docs/manual.md")
    assert manual =~ "the\nprompt doesn't ask for the suite again"
    assert manual =~ "The pull request's CI is the one full test run."
    assert manual =~ "but not\nthe project's toolchain"

    assert read("docs/agents.md") =~ "its CI is the one full test run"

    assert read("CLAUDE.md") =~
             "The PR's CI is the full suite: before pushing, run the tests you added or changed"
  end
end
