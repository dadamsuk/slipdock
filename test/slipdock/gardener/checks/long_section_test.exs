defmodule Slipdock.Gardener.Checks.LongSectionTest do
  @moduledoc "Handbook sections over the seed's length, and the split proposed for them (#1790)."
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures
  import Slipdock.GardenerHelpers

  alias Slipdock.{Boards, Gardener, Handbook, Wiki}
  alias Slipdock.Gardener.Checks.LongSection
  alias Slipdock.Gardener.Settings
  alias Slipdock.Wiki.Section

  setup do
    user = user_fixture()
    board = board_fixture(%{}, owner: user)
    %{user: user, board: board}
  end

  defp install(user, board) do
    {:ok, _} = Handbook.install(user, board)
    Handbook.find(board)
  end

  defp page(board, title), do: Enum.find(Handbook.find(board).pages, &(&1.title == title))

  defp set_body(page, body, user) do
    {:ok, page} = Wiki.update_page(page, %{"body" => body}, user: user)
    page
  end

  # `n` characters of prose, in lines.
  defp prose(n), do: "word " |> String.duplicate(div(n, 5)) |> String.trim()

  defp comments(page),
    do: Repo.all(from(c in Boards.Comment, where: c.page_id == ^page.id, select: c.body))

  test "a board without a handbook finds nothing, however long its pages", %{
    user: user,
    board: board
  } do
    page_fixture(board, %{"body" => "## Deploy\n\n" <> prose(4000)}, user: user)
    assert find(LongSection, board) == []
  end

  test "a new handbook has nothing too long", %{user: user, board: board} do
    install(user, board)
    assert find(LongSection, board) == []
  end

  test "a long section with a ### is split there, and applying it makes two sections",
       %{user: user, board: board} do
    hb = install(user, board)
    intro = prose(900)
    rollback = prose(900)

    body =
      "# Operations\n\n## Deploy\n\n#{intro}\n\n### Rollback\n\n#{rollback}\n\n#### Notes\n\nkeep\n\n" <>
        "## Configuration\n\nShort.\n"

    ops = set_body(page(board, "Operations"), body, user)

    assert [finding] = find(LongSection, board)
    assert finding.subject == %{"pages" => [ops.id, hb.index.id]}
    assert finding.explanation =~ "§Operations/Deploy of “Operations” is"
    assert finding.explanation =~ "over 1500"
    assert finding.explanation =~ "split it at “### Rollback” into two `##` sections"

    assert [%{"op" => "edit_section", "page" => id, "section" => "Operations/Deploy"} = step] =
             finding.proposal

    assert id == ops.id
    assert {:ok, step["base"]} == Gardener.Steps.current_section_hash(ops, "Operations/Deploy")
    assert %{"comment" => [%{"op" => "comment", "page" => index_id}]} = finding.alternatives
    assert index_id == hb.index.id

    {:ok, _} = Gardener.run(board, only: ["long_section"])
    [s] = Gardener.list_open(board)
    assert Gardener.person_only?(s)
    assert {:ok, _} = Gardener.apply(s, user)

    after_body = Repo.reload!(ops).body

    assert ["Operations/Deploy", "Operations/Rollback", "Operations/Configuration"] ==
             for(h <- Section.headings(after_body), h.level == 2, do: h.path)

    assert {:ok, deploy} = Section.read(after_body, "Operations/Deploy")
    assert deploy =~ intro
    refute deploy =~ "Rollback"
    assert {:ok, split} = Section.read(after_body, "Operations/Rollback")
    assert split =~ rollback
    assert split =~ "#### Notes\n\nkeep"
    # Nothing lost: the same lines, one heading promoted.
    assert String.replace(after_body, "## Rollback", "### Rollback") |> String.trim() ==
             String.trim(body)

    # Each half is under the limit now, so the next look finds nothing.
    assert find(LongSection, board) == []
  end

  test "with no ### to split at, the fix asks on the Index; applying and undoing it",
       %{user: user, board: board} do
    hb = install(user, board)
    ops = set_body(page(board, "Operations"), "## Deploy\n\n#{prose(1600)}\n", user)

    assert [finding] = find(LongSection, board)
    assert [%{"op" => "comment", "page" => index_id, "body" => text}] = finding.proposal
    assert index_id == hb.index.id
    assert text =~ "**Handbook upkeep.** §Deploy of “Operations” is"
    assert text =~ "Split §Deploy of “Operations” (#{ops.code})"
    refute Map.has_key?(finding, :alternatives)

    {:ok, _} = Gardener.run(board, only: ["long_section"])
    [s] = Gardener.list_open(board)
    refute Gardener.person_only?(s)
    assert {:ok, applied} = Gardener.apply(s, user)
    assert [^text] = comments(hb.index)
    assert {:ok, _} = Gardener.undo(applied, user)
    assert comments(hb.index) == []
  end

  test "a ### right under the heading is no place to split; the next one is",
       %{user: user, board: board} do
    install(user, board)

    set_body(
      page(board, "Operations"),
      "## Deploy\n\n### Steps\n\n#{prose(800)}\n\n### Rollback\n\n#{prose(800)}\n",
      user
    )

    assert [finding] = find(LongSection, board)
    assert finding.explanation =~ "split it at “### Rollback”"

    set_body(page(board, "Operations"), "## Deploy\n\n### Steps\n\n#{prose(1600)}\n", user)
    assert [%{proposal: [%{"op" => "comment"}]}] = find(LongSection, board)
  end

  test "no split when the promoted heading would clash with a ## already there",
       %{user: user, board: board} do
    install(user, board)

    set_body(
      page(board, "Operations"),
      "## Deploy\n\n#{prose(800)}\n\n### Rollback\n\n#{prose(800)}\n\n## Rollback\n\nShort.\n",
      user
    )

    assert [%{proposal: [%{"op" => "comment"}]}] = find(LongSection, board)
  end

  test "near misses: at the limit, a long Rules section, the Index's Log, a long ### alone",
       %{user: user, board: board} do
    hb = install(user, board)
    # 1,500 characters exactly, heading included, is not over.
    at_limit = "## Deploy\n\n" <> String.duplicate("x", 1500 - String.length("## Deploy\n\n"))
    set_body(page(board, "Operations"), at_limit <> "\n", user)

    rules =
      for i <- 1..40,
          do: "- **TEST-#{i}** should · judgement · A rule long enough to count for something."

    set_body(page(board, "Testing & tooling"), "## Rules\n\n" <> Enum.join(rules, "\n"), user)

    # The Index's two logs, each long: the Log and the Triage (#1791).
    {:ok, logged} =
      Wiki.append_section(
        hb.index,
        "Handbook/Log",
        String.duplicate("- 2026-01-01: a..b (20 commits)\n", 80)
      )

    {:ok, _} =
      Wiki.append_section(
        logged,
        "Handbook/Triage",
        String.duplicate("- 2026-01-01: 9 read, 2 merged, 1 dismissed, 4 promoted\n", 60)
      )

    assert find(LongSection, board) == []

    # Over by one is found.
    set_body(page(board, "Operations"), at_limit <> "y\n", user)
    assert [_] = find(LongSection, board)
  end

  test "decision pages are checked too", %{user: user, board: board} do
    install(user, board)
    {:ok, dec} = Wiki.Folders.find(board, "/" <> Handbook.decisions_folder())

    {:ok, page} =
      Wiki.create_page(board, %{
        "title" => "Decision: Postgres",
        "folder_id" => dec.id,
        "body" => "## Context\n\n#{prose(1700)}\n"
      })

    assert [%{subject: %{"pages" => [id | _]}}] = find(LongSection, board)
    assert id == page.id
  end

  test "chars is a setting; off is off; a dismissal lasts until the section changes",
       %{user: user, board: board} do
    install(user, board)
    # The seeded Playbook's Card shape (#2041) and Principles' Baseline (#2112)
    # are over 800 too: out of the way.
    set_body(page(board, "Playbook"), "## Sizing\n\nEverything is a card.\n", user)
    set_body(page(board, "Principles"), "## Baseline\n\n**Boring tech.** Postgres.\n", user)
    set_body(page(board, "Operations"), "## Deploy\n\n#{prose(1000)}\n", user)

    assert find(LongSection, board) == []
    assert [_] = find(LongSection, board, settings: %{"chars" => 800})
    assert {:ok, board} = Settings.put(board, LongSection, %{"chars" => 800})
    assert Settings.for(board, LongSection) == %{"enabled" => true, "chars" => 800}

    {:ok, _} = Gardener.run(board, only: ["long_section"])
    [s] = Gardener.list_open(board)
    {:ok, _} = Gardener.dismiss(s, user)
    {:ok, run} = Gardener.run(board, only: ["long_section"])
    assert run.counts["total"] == 0

    set_body(page(board, "Operations"), "## Deploy\n\n#{prose(1100)}\n", user)
    {:ok, run} = Gardener.run(board, only: ["long_section"])
    assert run.counts["total"] == 1

    # Off: a changed section is suggested afresh no more.
    {:ok, board} = Settings.put(board, LongSection, %{"enabled" => false})
    set_body(page(board, "Operations"), "## Deploy\n\n#{prose(1200)}\n", user)
    {:ok, run} = Gardener.run(board, only: ["long_section"])
    assert run.counts["new"] == 0
  end
end
