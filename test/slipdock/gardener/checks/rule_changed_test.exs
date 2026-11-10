defmodule Slipdock.Gardener.Checks.RuleChangedTest do
  @moduledoc """
  Rules an agent changed without a person's yes (#1791): one suggestion
  per page naming the rules, none for a person's edit or an agent's
  description; keeping records the approval, reverting puts the approved
  rules back and leaves the rest of the page alone.
  """
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures
  import Slipdock.GardenerHelpers

  alias Slipdock.{Actor, Gardener, Handbook, Repo, Wiki}
  alias Slipdock.Gardener.Checks.RuleChanged
  alias Slipdock.Wiki.Page

  setup do
    user = user_fixture()
    board = board_fixture(%{}, owner: user)
    {:ok, _} = Handbook.install(user, board)
    %{user: user, board: board}
  end

  defp ux(board), do: Enum.find(Handbook.find(board).pages, &(&1.title == "UX & UI"))

  defp body(intro, rules),
    do: "# UX & UI\n\n#{intro}\n\n## Patterns\n\nLists stream.\n\n## Rules\n\n#{rules}"

  @one "- **UX-1** must · judgement · Tokens only.\n"
  @two @one <> "- **UX-2** should · judgement · Prefer streams.\n"

  # A person (the web editor) or an agent (a token at the CLI) saving the page.
  defp person(board, user, text), do: save(board, user, text, "web")
  defp agent(board, user, text), do: save(board, user, text, "cli")

  defp save(board, user, text, via) do
    {:ok, page} = Wiki.update_page(ux(board), %{"body" => text}, user: user, via: via)
    page
  end

  defp run(board) do
    {:ok, _} = Gardener.run(board, only: ["rule_changed"])
    Gardener.list_open(board, check: "rule_changed")
  end

  test "a board without a handbook finds nothing", %{user: user} do
    bare = board_fixture(%{"name" => "Bare"}, owner: user)
    page_fixture(bare, %{"body" => "## Rules\n\n" <> @one}, user: user)
    assert find(RuleChanged, bare) == []
  end

  test "an agent adding a rule is found, naming it; a person's doing so isn't",
       %{user: user, board: board} do
    person(board, user, body("How screens are built.", @one))
    assert find(RuleChanged, board) == []

    agent(board, user, body("How screens are built.", @two))
    assert [finding] = find(RuleChanged, board)
    assert finding.explanation =~ "An agent changed the rules on “UX & UI”"
    assert finding.explanation =~ "added UX-2"
    refute finding.explanation =~ "UX-1"
    assert finding.subject["pages"] == [ux(board).id]

    # A person saving the page after it approves what is there.
    person(board, user, body("How screens are built, with care.", @two))
    assert find(RuleChanged, board) == []
  end

  test "rewording and removing are found; an agent's description edit isn't",
       %{user: user, board: board} do
    person(board, user, body("Intro.", @two))

    agent(board, user, body("A new intro, by an agent.", @two))
    assert find(RuleChanged, board) == []

    reworded = "- **UX-1** must · test/app/tokens_test.exs · Tokens only.\n"
    agent(board, user, body("A new intro, by an agent.", reworded))
    assert [finding] = find(RuleChanged, board)
    assert finding.explanation =~ "reworded UX-1; removed UX-2"
  end

  test "a page no person ever wrote compares with nothing approved", %{user: user, board: board} do
    agent(board, user, body("Intro.", @one))
    # The install's skeleton was written by the person who installed it.
    assert [finding] = find(RuleChanged, board)
    assert finding.explanation =~ "added UX-1"
  end

  test "keeping records the approval: no repeat, and only a later change is named",
       %{user: user, board: board} do
    person(board, user, body("Intro.", @one))
    agent(board, user, body("Intro.", @two))

    assert [s] = run(board)
    assert Gardener.person_only?(s)
    assert {:error, _} = Gardener.dismiss(s, user, actor: Actor.runner(user, 1))
    assert {:ok, _} = Gardener.dismiss(s, user, actor: Slipdock.Actor.web(user))

    assert run(board) == []

    agent(board, user, body("Intro.", @two <> "- **UX-3** must · judgement · No hover-only.\n"))
    assert [again] = run(board)
    assert again.explanation =~ "added UX-3"
    refute again.explanation =~ "UX-2"
  end

  test "reverting restores the approved rules and leaves the rest of the page alone",
       %{user: user, board: board} do
    person(board, user, body("Intro.", @one))
    agent(board, user, body("An agent's intro.", @two))

    assert [s] = run(board)
    assert {:ok, _} = Gardener.apply(s, user, actor: Slipdock.Actor.web(user))

    page = Repo.get!(Page, ux(board).id)
    assert page.body =~ "An agent's intro."
    assert page.body =~ "## Patterns\n\nLists stream."
    assert {_path, rules} = RuleChanged.rules_section(page.body)
    assert rules =~ "**UX-1**"
    refute rules =~ "**UX-2**"

    # Applied by a person through the gardener: approved, so nothing more.
    assert run(board) == []
  end

  test "a revert is refused once the rules have been edited again", %{user: user, board: board} do
    person(board, user, body("Intro.", @one))
    agent(board, user, body("Intro.", @two))
    assert [s] = run(board)

    person(board, user, body("Intro.", @two <> "- **UX-4** should · judgement · Short labels.\n"))
    assert {:error, message} = Gardener.apply(s, user, actor: Slipdock.Actor.web(user))
    assert message =~ "has changed since this was proposed"
  end

  test "changes/3 reads severity, scope, check and text as the rule" do
    page = %Page{title: "UX & UI", body: ""}
    before = "## Rules\n\n- **UX-1** must · judgement · A.\n- **UX-10** must · judgement · B.\n"

    assert RuleChanged.changes(page, before, before) == []

    after_ =
      "## Rules\n\n- **UX-1** should · judgement · A.\n- **UX-2** must · judgement · C.\n"

    assert RuleChanged.changes(page, before, after_) ==
             [{:reworded, "UX-1"}, {:added, "UX-2"}, {:removed, "UX-10"}]
  end
end
