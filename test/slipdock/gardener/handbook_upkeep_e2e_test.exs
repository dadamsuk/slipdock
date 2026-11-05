defmodule Slipdock.Gardener.HandbookUpkeepE2ETest do
  @moduledoc """
  Handbook upkeep end to end (epic #1786, W-2310 §Upkeep): a handbook kept
  true without being rewritten. The three jobs and the principle, across
  the subcards:

    * reconcile and triage come every night (#1787, #1789), and a range's
      paths name the pages to read (#1787);
    * hygiene checks run with the gardener (#1790);
    * an agent proposes a rule rather than writing it, and only a person
      applies it (#1788);
    * an agent's own edit to a rule is flagged for a person to keep or
      revert, and a person's edit, or a proposal they applied, is not
      (#1791).
  """
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Actor, Gardener, Handbook, Repo, Wiki}
  alias Slipdock.Boards.Card
  alias Slipdock.Wiki.Page

  @agent Actor.runner(nil, 1, "loop")

  setup do
    user = user_fixture()
    board = board_fixture(%{"name" => "Upkeep"}, owner: user)
    {:ok, _} = Handbook.install(user, board)
    %{user: user, board: board}
  end

  defp page(board, title), do: Enum.find(Handbook.find(board).pages, &(&1.title == title))

  defp save(page, body, user, via) do
    {:ok, page} =
      Wiki.update_page(Repo.get!(Page, page.id), %{"body" => body}, user: user, via: via)

    page
  end

  defp open(board, check) do
    {:ok, _} = Gardener.run(board, only: [check])
    Gardener.list_open(board, check: check)
  end

  @ux "# UX & UI\n\nHow screens are built.\n\n## Rules\n\n- **UX-1** must · judgement · Tokens only.\n"

  test "the nightly jobs: reconcile and triage repeat every day, and paths name the pages",
       %{user: user, board: board} do
    for title <- ["Reconcile the handbook", "Triage findings"] do
      card = Repo.get_by!(Card, board_id: board.id, title: title)
      assert Slipdock.Recurrence.for_card(card).rule == "FREQ=DAILY", title
    end

    ux = page(board, "UX & UI")

    {:ok, _} =
      Wiki.update_page(ux, %{
        "front_matter" => "---\nhandbook: ux\ncovers: [lib/app_web/live/**]\n---\n"
      })

    got =
      Handbook.rules_for_board(board, user, ["lib/app_web/live/menu.ex", "lib/app/repo.ex"])

    assert [%{title: "UX & UI", paths: 1}] = got.pages
  end

  test "a rule goes through a person: proposed, applied by them, and not flagged after",
       %{user: user, board: board} do
    ux = save(page(board, "UX & UI"), @ux, user, "web")

    {:ok, proposal, :new} =
      Gardener.propose(board, user, %{
        "explanation" => "UX-1 keeps breaking: name the tokens",
        "steps" => [
          %{
            "op" => "edit_section",
            "page" => ux.code,
            "section" => "UX & UI/Rules",
            "body" => "- **UX-1** must · judgement · Design tokens only, never hex."
          }
        ],
        "findings" => [1]
      })

    assert {:error, _} = Gardener.apply(proposal, user, actor: @agent)
    assert {:error, _} = Gardener.dismiss(proposal, user, actor: @agent)
    assert Repo.get!(Page, ux.id).body == ux.body

    assert {:ok, _} = Gardener.apply(proposal, user, actor: Actor.web(user))
    assert Repo.get!(Page, ux.id).body =~ "Design tokens only, never hex."

    # Applied by a person through the gardener: approved.
    assert open(board, "rule_changed") == []
  end

  test "an agent's own rule edit is flagged; a person reverts it and the rest stays",
       %{user: user, board: board} do
    ux = save(page(board, "UX & UI"), @ux, user, "web")

    agent_body =
      String.replace(@ux, "How screens are built.", "How screens are built, by an agent.") <>
        "- **UX-2** must · judgement · No hover-only controls.\n"

    save(ux, agent_body, user, "cli")

    assert [flag] = open(board, "rule_changed")
    assert flag.explanation =~ "added UX-2"
    assert {:error, _} = Gardener.dismiss(flag, user, actor: @agent)

    assert {:ok, _} = Gardener.apply(flag, user)
    body = Repo.get!(Page, ux.id).body
    assert body =~ "by an agent."
    refute body =~ "UX-2"
    assert open(board, "rule_changed") == []
  end

  test "hygiene runs with the gardener, and a long section's split is a person's",
       %{user: user, board: board} do
    long =
      "# Operations\n\n## Deploy\n\nIntro.\n\n### Steps\n\n" <>
        String.duplicate("A deploy step worth writing down.\n", 60)

    save(page(board, "Operations"), long, user, "cli")

    {:ok, _} = Gardener.run(board)
    assert [split] = Gardener.list_open(board, check: "long_section")
    assert Gardener.person_only?(split)
    assert {:error, _} = Gardener.apply(split, user, actor: @agent)
  end
end
