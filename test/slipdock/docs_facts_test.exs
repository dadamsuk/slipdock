defmodule Slipdock.DocsFactsTest do
  @moduledoc """
  `Slipdock.DocsFacts` (#2794): a docs test holds a doc to the facts a claim
  states, so the doc can be reworded without a test edit, and still fails
  when a fact goes or moves away from the passage.
  """
  use ExUnit.Case, async: true

  import Slipdock.DocsFacts

  @claim "Complete it with `slipdock done <id> --pr <url>` once the pull request's checks pass (#2794)."

  test "the facts and key words of a claim" do
    assert {facts, words} = terms(@claim)
    assert facts == ["slipdock done <id> --pr <url>", "#2794"]
    assert words == ~w(complete pull request's checks pass)

    assert {["--paths", "W-1950", "TEST-4", "docs/manual/lanes.md", "paths_broad", "22,000"], _} =
             terms(
               "Give --paths (W-1950, TEST-4) in docs/manual/lanes.md as paths_broad, 22,000 B"
             )

    assert {["Principles/Baseline", "--append"], []} =
             terms(~s{"Principles/Baseline" --append -`})

    assert {["https://example.com/a"], ["read"]} = terms("Read https://example.com/a.")

    # A short quotation is a fact; a long one is prose, so it can be reworded.
    assert {["the build is green"], words} =
             terms(~s{Say "the build is green" or "this sentence is far too long to pin"})

    assert "sentence" in words
  end

  test "the claim as written passes, and so does a rewording of it" do
    assert states?(@claim, @claim)

    reworded = """
    When every check on the pull request has passed, complete the card:
    `slipdock done <id> --pr <url>`. See #2794.
    """

    assert states?(reworded, @claim)
    assert assert_states(reworded, @claim)
  end

  test "a fact changed or gone fails, and the message names it" do
    renamed = String.replace(@claim, "--pr", "--pull-request")
    refute states?(renamed, @claim)
    refute states?(String.replace(@claim, " (#2794)", ""), @claim)

    error = assert_raise ExUnit.AssertionError, fn -> assert_states(renamed, @claim, "skill") end
    assert error.message =~ "skill\n"
    assert error.message =~ ~s{"slipdock done <id> --pr <url>"}
  end

  test "facts far apart in the doc are not the claim's passage" do
    filler = String.duplicate("Something else entirely is said here. ", 30)
    apart = "Complete it with `slipdock done <id> --pr <url>`. " <> filler <> "(#2794)"
    refute states?(apart, @claim)
  end

  test "a claim with no facts needs most of its key words in one place" do
    claim = "Install it only when the person says yes"
    assert states?("Ask first, and install it only once the person agrees: a yes.", claim)
    refute states?("Install it.", claim)
    refute states?("The person can say yes later.", claim)
  end

  test "whitespace is collapsed, so a wrapped doc matches" do
    assert states?(
             "Complete it with `slipdock done <id>\n  --pr <url>`, once the\nchecks pass (#2794).",
             @claim
           )
  end

  test "a claim with neither facts nor key words is matched as written" do
    assert states?("it is so: a b c", "a b c")
    refute states?("it is so", "a b c")
  end

  describe "the passage (the rejection's surviving mutants, #2794)" do
    # Every key word and one fact together; the other fact 300 or more
    # characters off, further than the 240-character window of this claim.
    test "a fact outside the window fails, though the key words and the other fact are there" do
      assert 2 * String.length(@claim) < 240
      filler = String.duplicate("Something else entirely is said here. ", 9)
      assert String.length(filler) in 300..400

      apart =
        "Complete the card once the pull request's checks pass (#2794). " <>
          filler <> "`slipdock done <id> --pr <url>`"

      refute states?(apart, @claim)

      error = assert_raise ExUnit.AssertionError, fn -> assert_states(apart, @claim) end
      assert error.message =~ "missing near each other: "
      # Only the fact out of reach is named: the key words were all found.
      refute error.message =~ ~s{"complete"}
    end

    test "the window is never under 240 characters: a fact 200 off a short claim counts" do
      claim = "Give `--pr` (#2794)"
      assert 2 * String.length(claim) < 100
      filler = String.duplicate("x ", 100)
      assert states?("Give `--pr` " <> filler <> "(#2794)", claim)
      refute states?("Give `--pr` " <> String.duplicate("x ", 150) <> "(#2794)", claim)
    end

    test "a long claim's window is twice its length, past 240 characters" do
      claim =
        "Complete it with `slipdock done <id> --pr <url> --evidence-commit <sha>` once " <>
          "every one of the pull request's checks has passed, giving the suite's counts " <>
          "and the run in the evidence (#2794)."

      assert String.length(claim) in 180..200
      words = "complete every pull request's checks passed giving suite's counts evidence "
      near = "`slipdock done <id> --pr <url> --evidence-commit <sha>` " <> words
      assert states?(near <> String.duplicate("x ", 100) <> "#2794", claim)
      refute states?(near <> String.duplicate("x ", 250) <> "#2794", claim)
    end

    test "the facts alone are not the claim: a third of its key words must be there too" do
      refute states?("`slipdock done <id> --pr <url>` #2794", @claim)
      # Five key words need two: one is short, two are enough.
      refute states?("`slipdock done <id> --pr <url>` #2794 checks", @claim)
      assert states?("`slipdock done <id> --pr <url>` #2794 checks pass", @claim)
    end

    test "key words outside the window don't count" do
      filler = String.duplicate("Something else entirely is said here. ", 9)

      refute states?(
               "`slipdock done <id> --pr <url>` #2794 " <> filler <> "the checks pass",
               @claim
             )
    end

    test "a claim with no facts needs three in five of its key words, no fewer" do
      claim = "The agent reads the handbook before building anything large"
      assert {[], ~w(agent reads handbook building large)} = terms(claim)
      assert states?("An agent reads the handbook.", claim)
      refute states?("An agent has a handbook.", claim)
    end

    test "must, never and should are key words: a claim's force can't be dropped" do
      claim = "An agent must never merge it"
      assert {[], ~w(agent must never merge)} = terms(claim)
      assert states?("The agent must never merge the pull request.", claim)
      refute states?("The agent may merge the pull request.", claim)
      # An ordinary stop word is not one.
      assert {[], ~w(agent merge)} = terms("An agent would always merge it")
    end

    test "a claim cut mid code span keeps the tail as prose, not as a fact" do
      assert {[], ~w(complete slipdock checks pass)} =
               terms("Complete it with `slipdock done when checks pass")

      assert {["slipdock done"], ~w(complete checks pass)} =
               terms("Complete it with `slipdock done` when checks pass")

      # The span before the cut is still a fact.
      assert {["slipdock done"], ~w(checks pass)} = terms("`slipdock done` then `checks pass")
    end
  end
end
