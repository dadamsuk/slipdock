defmodule SlipdockWeb.BatchedReleasesDocsTest do
  @moduledoc """
  Batched releases (#2833) as the docs say them (#2839): the manual has a
  page of its own, in the contents between Verified work and Lanes, and
  every place a reader or an agent looks says the three things a batched
  board changes: a card is done when it merges, *Release now* is how a
  person ships, and *Not shipped* counts from the card's release, not its
  merge.
  """
  use ExUnit.Case, async: true

  import Slipdock.DocsFacts, only: [assert_states: 2, assert_states: 3]

  @root Path.expand("../..", __DIR__)
  defp read(path), do: Slipdock.DocsText.read!(Path.join(@root, path))

  test "the manual has the page, in the contents between Verified work and Lanes" do
    lines = @root |> Path.join("docs/manual.md") |> File.read!() |> String.split("\n")
    at = fn line -> Enum.find_index(lines, &(&1 == line)) end

    verified = at.("- [Verified work](manual/verified-work.md)")
    batched = at.("- [Batched releases](manual/batched-releases.md)")
    assert is_integer(verified) and is_integer(batched)
    assert batched > verified

    # Only Verified work's own sub-headings come between them, and Lanes is next.
    between = Enum.slice(lines, (verified + 1)..(batched - 1)//1)
    assert Enum.all?(between, &String.starts_with?(&1, "  - "))
    assert Enum.at(lines, batched + 1) == "- [Lanes](manual/lanes.md)"

    page = File.read!(Path.join(@root, "docs/manual/batched-releases.md"))
    assert page =~ ~r/^## Batched releases$/m

    for part <- [
          "**Why batch.**",
          "**What starts a release.**",
          "**Who fires it.**",
          "**Your release workflow.**",
          "**How it ends.**",
          "**Merged, not shipped.**",
          "`on_merge`",
          "--release-mode batched --release-age-cap 24",
          "Merged 1a2b3c4, awaiting release",
          "Released to production",
          "slipdock release <board>",
          "/api/boards/:board/release",
          "`release_now`",
          "gh workflow run\nrelease.yml --ref {default_branch}",
          "`release_commands`",
          "`workflow_dispatch`",
          "--lift-hold",
          "`release_requested_at`"
        ],
        do: assert(page =~ part, inspect(part))

    assert_states(page, "Releases run one at a time")
    assert_states(page, "A red release holds releases")

    # The section left Verified work, which points at the page instead.
    verified_work = File.read!(Path.join(@root, "docs/manual/verified-work.md"))
    refute verified_work =~ "### Batched releases"
    refute verified_work =~ "release_age_cap"
    assert verified_work =~ "[Batched releases](batched-releases.md)"

    assert read("README.md") =~ "docs/manual/batched-releases.md"
    assert read("docs/agents.md") =~ "(manual/batched-releases.md)"
  end

  test "every place says Not shipped counts from the release, not the merge" do
    for path <- [
          "README.md",
          "docs/agents.md",
          "docs/manual/batched-releases.md",
          "docs/manual/delivery-metrics-deploys-and-dora.md",
          "lib/slipdock_web/api_guide.ex",
          "lib/slipdock_web/live/help_live/guides.ex",
          "lib/slipdock_web/live/help_live/agents.ex",
          "lib/slipdock_web/live/help_live/flow.ex",
          "cli/help.txt",
          "priv/skills/slipdock/SKILL.md",
          "priv/skills/slipdock-work/SKILL.md"
        ] do
      assert_states(
        read(path),
        "shipped count from the card's release, not its merge",
        "#{path} doesn't say Not shipped counts from the release, not the merge"
      )
    end

    assert read("docs/manual/the-overseer.md") =~ "since its release started"

    # The field and the line's words, where the card's JSON is described.
    for path <- [
          "docs/agents.md",
          "docs/manual/batched-releases.md",
          "docs/manual/delivery-metrics-deploys-and-dora.md",
          "lib/slipdock_web/api_guide.ex",
          "lib/slipdock_web/live/help_live/flow.ex"
        ] do
      assert read(path) =~ "release_requested_at", "#{path} doesn't name release_requested_at"
    end

    for path <- [
          "docs/agents.md",
          "docs/manual/batched-releases.md",
          "lib/slipdock_web/api_guide.ex"
        ] do
      assert_states(read(path), "not shipped 45m after its release started")
    end

    assert SlipdockWeb.APIGuide.markdown() =~ "release_requested_at"
  end

  test "every place says a card is done on merge and Release now is how a person ships" do
    for path <- [
          "docs/agents.md",
          "docs/manual/batched-releases.md",
          "lib/slipdock_web/api_guide.ex",
          "lib/slipdock_web/live/help_live/guides.ex",
          "lib/slipdock_web/live/help_live/agents.ex",
          "priv/skills/slipdock/SKILL.md",
          "priv/skills/slipdock-work/SKILL.md"
        ] do
      text = read(path)

      assert_states(
        text,
        "Release now is how a person ships",
        "#{path} doesn't say Release now is how a person ships"
      )

      assert_states(
        text,
        "a card is done when it merges, and nothing waits for its release",
        "#{path} doesn't say a card is done when it merges"
      )
    end

    work = read("priv/skills/slipdock-work/SKILL.md")
    assert_states(work, "don't wait for its release")
    assert_states(work, "Never run it to finish a card, only when the person asks")
    assert work =~ "slipdock release <board>"
    assert work =~ "slipdock releases <board>"
  end
end
