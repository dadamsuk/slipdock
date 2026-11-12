defmodule SlipdockWeb.DocsPlacesDocsTest do
  @moduledoc """
  How SPEC-10 is judged (#2694, #2697): the manual's Verified work page,
  `docs/agents.md`, the API guide, the loop skill, the agents help's
  handbook part and the Flow page say it is checked by enumeration, give
  the four results, and say a deferral counts only when its card's bar
  names the place.
  """
  use SlipdockWeb.ConnCase, async: true

  import Slipdock.DocsFacts, only: [assert_states: 2]

  import Phoenix.LiveViewTest

  @root Path.expand("../..", __DIR__)

  defp flat(text), do: String.replace(text, ~r/\s+/u, " ")

  defp read(path), do: @root |> Path.join(path) |> File.read!() |> flat()

  test "the manual's Verified work page says how SPEC-10 is judged" do
    manual = @root |> Path.join("docs/manual/verified-work.md") |> File.read!() |> flat()

    assert_states(manual, "**SPEC-10 is checked by enumeration, not judged.**")
    assert_states(manual, "take the names the change introduces or alters from the diff")
    assert_states(manual, "grep them across the seven places")

    assert_states(
      manual,
      "*updated*, *deferred to #N* (only when card #N's bar names that place), *n/a* with why, or *missing*"
    )

    assert manual =~ "One missing is `--check rule:SPEC-10=broken:<file>:<name>`"

    assert_states(
      manual,
      "a deferral to a card whose bar doesn't name the place counts as missing"
    )

    assert_states(manual, "list each place its lane can't reach on the deferral card's bar")
  end

  test "docs/agents.md's Verified work says it, beside the every-instance rule" do
    agents = read("docs/agents.md")
    [_, after_instances] = String.split(agents, "**A rejection names every instance found**")
    [passage, _] = String.split(after_instances, "A card resubmitted after a rejection", parts: 2)

    assert_states(passage, "**SPEC-10 is checked by enumeration, not judged**")
    assert_states(passage, "lists the names the change introduces or alters from the diff")
    assert_states(passage, "greps them across the seven places")

    assert_states(
      passage,
      "*updated*, *deferred to #N* (only when card #N's bar names that place), *n/a* with why, or *missing*"
    )

    assert passage =~ "One missing is `--check rule:SPEC-10=broken:<file>:<name>`, a rejection"

    assert_states(
      passage,
      "a deferral to a card whose bar doesn't name the place counts as missing"
    )

    assert_states(passage, "a place its lane can't reach goes on the deferral card's bar by name")
    assert_states(passage, "one missing there is a disagreement")
  end

  test "the API guide's Verified work section says it, inside the size caps (SPEC-4)", %{
    user: user
  } do
    # The section is written only for a user with a verifying board.
    assert {:error, _} = SlipdockWeb.APIGuide.section("verified", user: user)

    board =
      Slipdock.Fixtures.board_fixture(
        %{"name" => "Verify", "code" => Slipdock.Fixtures.unique_code()},
        owner: user
      )

    {:ok, _} = Slipdock.Boards.update_board(board, %{"verify_work" => true})

    {:ok, verified} = SlipdockWeb.APIGuide.section("verified", user: user)
    [_, verified] = String.split(flat(verified), "**A second agent verifies.**", parts: 2)

    assert_states(verified, "`SPEC-10` is checked by enumeration, not judged")
    assert_states(verified, "List the names the change introduces or alters from the diff")
    assert_states(verified, "grep them across the seven places")

    assert_states(
      verified,
      "updated, deferred to #N (only when card #N's bar names that place), n/a with why, or missing"
    )

    assert verified =~ "One missing is `rule:SPEC-10=broken:<file>:<name>`"

    assert_states(
      verified,
      "a place its lane can't reach goes on the deferral card's bar by name, or the deferral doesn't count"
    )

    # SPEC-4: the passage is in the Verified work section alone; the short
    # guide never carries it, and keeps its cap.
    short = SlipdockWeb.APIGuide.short()
    refute short =~ "checked by enumeration"
    refute SlipdockWeb.APIGuide.short(user: user) =~ "checked by enumeration"
    assert byte_size(short) < 22_000
  end

  test "the loop skill says it: a verify job, an audit, and the builder before submitting" do
    skill = File.read!(Path.join(@root, "priv/skills/slipdock-loop/SKILL.md"))

    [_, verify_job] = String.split(skill, "- **A verify job**", parts: 2)
    [verify_job, audit] = String.split(verify_job, "- **An audit**", parts: 2)
    [audit | _] = String.split(audit, "\n## ", parts: 2)
    verify_job = flat(verify_job)

    assert verify_job =~ "**`SPEC-10` is enumerated, not judged**"
    assert_states(verify_job, "list the names the change introduces or alters from the diff")
    assert_states(verify_job, "grep them across the seven places")

    assert_states(
      verify_job,
      "`updated`, `deferred to #N` (only when card #N's bar names that place: `slipdock card N`), `n/a` with why, or `missing`"
    )

    assert verify_job =~ "One missing is `--check rule:SPEC-10=broken:<file>:<name>`"

    assert_states(
      flat(audit),
      "The docs places (`SPEC-10`) are enumerated as in a verify job: one missing, a deferral to a card whose bar doesn't name the place included, is a disagreement."
    )

    [_, builder] = String.split(skill, "**Before\nsubmitting, check the diff against them**")
    [builder | _] = String.split(builder, "\n## ", parts: 2)
    builder = flat(builder)

    assert builder =~ "**The docs places (`SPEC-10`)**"
    assert_states(builder, "grep each across the seven places")
    assert_states(builder, "*updated*, *deferred to #N*, *n/a* with why, or *missing*")

    assert_states(
      builder,
      "A place the lane can't reach goes on the deferral card's bar by name, with the names it must cover"
    )

    assert builder =~ "or the deferral doesn't count"
  end

  test "the agents help's handbook part says it", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/help/agents/skills")
    doc = LazyHTML.from_document(html)
    text = doc |> LazyHTML.query("#help-handbook-docs-places") |> LazyHTML.text() |> flat()

    assert_states(text, "is checked by enumeration, not judged")
    assert_states(text, "greps them across the seven places")

    assert_states(
      text,
      "updated, deferred to a card whose bar names that place, not applicable with why, or missing"
    )

    assert_states(text, "One missing is the rule broken")
    assert_states(text, "a deferral whose bar doesn't list the place doesn't count")
  end

  test "the Flow help page's verifier says it", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/help/agents/flow")
    text = html |> LazyHTML.from_document() |> LazyHTML.text() |> flat()

    assert text =~ "(SPEC-10) is checked by enumeration"

    assert_states(
      text,
      "updated, deferred to a card whose bar names that place, not applicable with why, or missing, and one missing is the rule broken"
    )
  end
end
