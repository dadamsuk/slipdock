defmodule Slipdock.Gardener.Checks.RuleWithoutCheckTest do
  @moduledoc "`must` rules left to judgement too long, and rule ids used twice (#1790)."
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures
  import Slipdock.GardenerHelpers

  alias Slipdock.{Gardener, Handbook, Wiki}
  alias Slipdock.Gardener.Checks.RuleWithoutCheck
  alias Slipdock.Gardener.Settings
  alias Slipdock.Wiki.Revision

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

  defp set_rules(page, items, user) do
    {:ok, page} = Wiki.update_page(page, %{"body" => "## Rules\n\n" <> items}, user: user)
    page
  end

  # Every revision of `page` `days` old.
  defp age_revisions(page, days) do
    at = DateTime.add(DateTime.utc_now(:second), -days * 86_400)
    Repo.update_all(from(r in Revision, where: r.page_id == ^page.id), set: [inserted_at: at])
  end

  test "a board without a handbook finds nothing", %{user: user, board: board} do
    page =
      page_fixture(board, %{"body" => "## Rules\n\n- **X-1** must · judgement · Old.\n"},
        user: user
      )

    age_revisions(page, 100)
    assert find(RuleWithoutCheck, board) == []
  end

  test "a must rule on judgement for over 30 days is found; its near misses aren't",
       %{user: user, board: board} do
    hb = install(user, board)
    assert find(RuleWithoutCheck, board) == []

    arch =
      set_rules(
        page(board, "Architecture"),
        """
        - **ARCH-1** must · judgement · Contexts never call each other's Repo.
        - **ARCH-2** should · judgement · Keep modules short.
        - **ARCH-3** must · test/app/boundary_test.exs · No cycles between contexts.
        """,
        user
      )

    age_revisions(arch, 31)

    assert [finding] = find(RuleWithoutCheck, board)
    assert finding.subject == %{"pages" => [arch.id, hb.index.id]}

    assert finding.explanation ==
             "ARCH-1 (must) on “Architecture” has been checked by judgement for 31 days"

    assert [%{"op" => "comment", "page" => index_id, "body" => body}] = finding.proposal
    assert index_id == hb.index.id
    assert body =~ "Write the test that enforces ARCH-1 on “Architecture” (#{arch.code})"
    assert body =~ "Contexts never call each other's Repo."

    # 29 days is not yet.
    age_revisions(arch, 29)
    assert find(RuleWithoutCheck, board) == []
    # A threshold of its own.
    assert [_] = find(RuleWithoutCheck, board, settings: %{"days" => 20})
  end

  test "judgement_since/2: the oldest of the newest revisions in a row that have it" do
    t = fn d -> DateTime.add(~U[2026-11-01 00:00:00Z], -d * 86_400) end
    judged = "- **UX-1** must · judgement · No hex."
    tested = "- **UX-1** must · test/x_test.exs · No hex."

    # Newest first: judgement since day 10, a test before that, judgement before.
    history = [{t.(1), judged}, {t.(10), "intro\n" <> judged}, {t.(20), tested}, {t.(40), judged}]
    assert RuleWithoutCheck.judgement_since(history, "UX-1") == t.(10)
    assert RuleWithoutCheck.judgement_since([{t.(1), tested}], "UX-1") == nil
    assert RuleWithoutCheck.judgement_since(history, "UX-12") == nil

    assert RuleWithoutCheck.judgement_since([{t.(5), "- **UX-1** must · judgment · x"}], "UX-1") ==
             t.(5)
  end

  test "a rule id used twice is found, across pages; distinct ids aren't",
       %{user: user, board: board} do
    hb = install(user, board)

    arch =
      set_rules(page(board, "Architecture"), "- **ARCH-1** must · test/a_test.exs · One.\n", user)

    data =
      set_rules(
        page(board, "Data model"),
        "- **DATA-1** must · test/b_test.exs · Two.\n- **ARCH-1** should · judgement · Three.\n",
        user
      )

    assert [finding] = find(RuleWithoutCheck, board)
    assert Enum.sort(finding.subject["pages"]) == Enum.sort([arch.id, data.id, hb.index.id])
    assert finding.explanation =~ "Rule id ARCH-1 is used 2 times: "
    assert finding.explanation =~ "#{arch.code} line 3"
    assert finding.explanation =~ "#{data.code} line 4"
    assert [%{"op" => "comment", "body" => body}] = finding.proposal
    assert body =~ "Keep ARCH-1 on #{arch.code} line 3, and give the others new ids"

    # Renumbered: nothing.
    set_rules(
      page(board, "Data model"),
      "- **DATA-1** must · test/b_test.exs · Two.\n- **DATA-2** should · judgement · Three.\n",
      user
    )

    assert find(RuleWithoutCheck, board) == []
  end

  test "an id twice on one page counts too", %{user: user, board: board} do
    install(user, board)

    set_rules(
      page(board, "Operations"),
      "- **OPS-1** must · test/a_test.exs · One.\n- **OPS-1** must · test/b_test.exs · Two.\n",
      user
    )

    assert [%{explanation: "Rule id OPS-1 is used 2 times: " <> _}] =
             find(RuleWithoutCheck, board)
  end

  test "applying comments on the Index and edits no rule; off is off", %{user: user, board: board} do
    hb = install(user, board)

    ops =
      set_rules(
        page(board, "Operations"),
        "- **OPS-1** must · judgement · Deploys are green.\n",
        user
      )

    age_revisions(ops, 45)
    {:ok, _} = Gardener.run(board, only: ["rule_without_check"])
    [s] = Gardener.list_open(board)
    refute Gardener.person_only?(s)
    {:ok, _} = Gardener.apply(s, user)
    assert Repo.reload!(ops).body == ops.body

    assert [_] =
             Repo.all(from(c in Slipdock.Boards.Comment, where: c.page_id == ^hb.index.id))

    {:ok, board} = Settings.put(board, RuleWithoutCheck, %{"enabled" => false, "days" => 60})
    assert Settings.for(board, RuleWithoutCheck) == %{"enabled" => false, "days" => 60}
    refute Settings.enabled?(board, RuleWithoutCheck)
  end
end
