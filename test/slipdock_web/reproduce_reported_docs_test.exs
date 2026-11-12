defmodule SlipdockWeb.ReproduceReportedDocsTest do
  @moduledoc """
  A bug that doesn't reproduce means ask, not make one (#1927): reproduced
  means the reported symptom on the reporter's scenario; a clean repro that
  doesn't show it opens a wait asking for a screenshot or steps, never
  conditions built until something fails; and the verifier's check on a bug
  is would the reporter now see it fixed. Every place the procedure is
  written says so.
  """
  use ExUnit.Case, async: true

  import Slipdock.DocsFacts, only: [assert_states: 2, assert_states: 3]

  @root Path.expand("../..", __DIR__)
  # Line breaks folded, for prose that is rewrapped as it changes.
  defp flat(path),
    do: @root |> Path.join(path) |> Slipdock.DocsText.read!() |> String.replace(~r/\s+/, " ")

  describe "the loop skill" do
    setup do: %{loop: flat("priv/skills/slipdock-loop/SKILL.md")}

    test "reproduced means the reported symptom, on the reporter's scenario", %{loop: loop} do
      assert_states(loop, "### A bug: reproduce what was reported")
      assert_states(loop, "**Reproduced means the reported symptom, on the reporter's scenario**")
      assert_states(loop, "Something else that fails nearby is not it.")
    end

    test "a clean repro that doesn't show it opens a wait, never builds conditions",
         %{loop: loop} do
      assert_states(loop, "**A clean repro that doesn't show it means ask, never make one.**")

      assert_states(
        loop,
        "Don't add conditions (a wider element, odd data, another size) until something fails"
      )

      assert_states(loop, "never fix a cause you invented")

      assert_states(
        loop,
        "Open a wait (`--kind other`, or `ux` for a screen) that says what you tried and what you saw"
      )

      assert_states(
        loop,
        "asks for a screenshot or the steps: which screen, which control, which size"
      )
    end

    test "pickup first, the repro as its own comment", %{loop: loop} do
      assert_states(loop, "**Post the *Picked up* comment first**, then reproduce")

      assert_states(
        loop,
        "post the repro as **its own comment** (`**Reproduced.**` or `**Not reproduced.**`)"
      )
    end

    test "a UI bug with no screenshot or steps gets them asked for first", %{loop: loop} do
      assert_states(
        loop,
        "**A UI bug with no screenshot or steps**, whose symptom you couldn't see, gets them asked for the same way, before any work starts."
      )
    end

    test "the verify job's ask: would the reporter now see it fixed", %{loop: loop} do
      assert_states(loop, "On a bug, the check is *would the reporter now see it fixed?*")
      assert_states(loop, "says the reported symptom or its cause was never seen")
      assert loop =~ "(`the ask: the reported symptom was never seen`), however good the tests."
    end
  end

  test "the agents page and the API guide say the same" do
    for path <- ["docs/agents.md", "lib/slipdock_web/api_guide.ex"] do
      text = flat(path)

      assert_states(
        text,
        "the check is would the reporter now see it fixed, not does the work meet the bar",
        path
      )

      assert_states(text, "reproduces the reported symptom on the reporter's scenario", path)
      assert_states(text, "posts the repro as its own comment", path)

      assert_states(
        text,
        "opens a wait saying what was seen and asking for a screenshot or steps (which screen, which control), never conditions built until something fails",
        path
      )

      assert_states(text, "says the reported symptom or its cause was never seen", path)
      assert text =~ "however good the tests", path
    end
  end

  test "the manual's verify jobs paragraph lists the ask on a bug" do
    manual = flat("docs/manual.md")
    [_, verify] = String.split(manual, "### Verify jobs", parts: 2)
    [paragraph | _] = String.split(verify, "A rejection cites what it fails", parts: 2)

    assert_states(
      paragraph,
      "On a bug, the check is would the reporter now see it fixed, not does the work meet the bar"
    )

    assert_states(
      paragraph,
      "says the reported symptom or its cause was never seen (a cause made up in the test) is a rejection on the ask, however good the tests"
    )
  end
end
