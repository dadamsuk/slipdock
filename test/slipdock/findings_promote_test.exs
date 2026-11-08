defmodule Slipdock.FindingsPromoteTest do
  @moduledoc """
  Promotion by recurrence (#1942): a finding counted to its board's
  `findings_propose_at` gets one garden proposal, an `edit_section` on the
  `## Rules` of the page covering its cards' paths (else Specification),
  drafted up the ladder; a person's accept promotes it, a dismissal waits
  for the count to rise by the threshold again, and a board without a
  handbook files nothing.
  """
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{AIStub, Boards, Findings, Gardener, Handbook, Repo, Wiki}
  alias Slipdock.Findings.{Finding, Promote}
  alias Slipdock.Gardener.Suggestion
  alias Slipdock.Wiki.Page

  setup do
    owner = user_fixture()
    board = board_fixture(%{"name" => "Promoting"}, owner: owner)
    {:ok, _} = Handbook.install(owner, board)
    pages = Map.new(Handbook.find(board).pages, &{Handbook.key(&1), &1})

    write(pages["ux"], "[lib/app_web/**]", """
    - **UX-1** should · judgement · Screens use the layout's header.
    - **UX-3** must · judgement · LiveViews stream long lists.
    """)

    write(pages["specification"], "[]", "- **SPEC-1** must · judgement · Every door.\n")

    board = Boards.get_board!(board.id)
    [_backlog, doing | _] = board.columns
    ui = card_fixture(doing, %{"title" => "A screen", "paths" => ["lib/app_web/live/x.ex"]})
    plain = card_fixture(doing, %{"title" => "No paths"})
    %{owner: owner, board: board, pages: pages, ui: ui, plain: plain, doing: doing}
  end

  defp write(page, covers, rules) do
    {:ok, _} =
      Wiki.update_page(page, %{
        "front_matter" => "---\nhandbook: #{Handbook.key(page)}\ncovers: #{covers}\n---\n",
        "body" => "# #{page.title}\n\nWhat it is.\n\n## Rules\n\n" <> rules
      })
  end

  # A finding seen `count` times on `card`, as from_comment would keep it.
  defp seen(ctx, card, text, count, attrs \\ []) do
    %Finding{
      board_id: ctx.board.id,
      card_id: card.id,
      kind: "gotcha",
      source: "agent",
      text: text,
      lesson: Slipdock.Findings.Lesson.normalise(text),
      count: count
    }
    |> struct(attrs)
    |> Repo.insert!()
  end

  defp proposals(board),
    do: Repo.all(from s in Suggestion, where: s.board_id == ^board.id and s.check == "proposal")

  defp step(%Suggestion{proposal: [step]}), do: step

  describe "the threshold" do
    test "a count below it files nothing; reaching it files one, recorded on the finding", ctx do
      AIStub.fail_with(503, "down")
      f = seen(ctx, ctx.ui, "screens must not flash on load", 2)
      assert Promote.check(f.id) == :skip
      assert proposals(ctx.board) == []

      Repo.update!(Ecto.Changeset.change(f, count: 3))
      assert {:ok, %Suggestion{id: id, state: "open"} = s} = Promote.check(f.id)

      assert %{proposal_id: ^id, proposed_rule: "UX-4", proposed_at_count: 3} =
               Repo.get!(Finding, f.id)

      assert s.explanation =~ "Finding ##{f.id} was seen 3 times (cards ##{ctx.ui.id})"
      assert s.subject["findings"] == [f.id]
    end

    test "exceeding it with one open files no second", ctx do
      AIStub.fail_with(503, "down")
      f = seen(ctx, ctx.ui, "screens must not flash on load", 3)
      {:ok, _} = Promote.check(f.id)

      Repo.update!(Ecto.Changeset.change(Repo.get!(Finding, f.id), count: 9))
      assert Promote.check(f.id) == :skip
      assert length(proposals(ctx.board)) == 1
    end

    test "0 is off", ctx do
      {:ok, _} = Boards.update_board(ctx.board, %{"findings_propose_at" => 0})
      f = seen(ctx, ctx.ui, "screens must not flash on load", 50)
      assert Promote.check(f.id) == :skip
    end

    test "a count reached through comments files it as the comment lands", ctx do
      AIStub.fail_with(503, "down")
      block = "- Findings:\n  - gotcha: screens must not flash on load"

      for _ <- 1..3, do: {:ok, _} = Boards.add_comment(ctx.ui, block, by: ctx.owner)

      assert [%Finding{count: 3, proposal_id: id}] =
               Repo.all(from f in Finding, where: f.card_id == ^ctx.ui.id)

      assert [%Suggestion{id: ^id}] = proposals(ctx.board)

      {:ok, _} = Boards.add_comment(ctx.ui, block, by: ctx.owner)
      assert length(proposals(ctx.board)) == 1
    end

    test "reworded repeats on other cards reach it too (#2117)", ctx do
      AIStub.fail_with(503, "down")

      said = [
        "gotcha: `mix pre_push` always tests in the `_pre_push` database, which every worktree shares, so a branch with other migrations fails with `duplicate_table`",
        "tooling: every worktree shares `mix pre_push`'s `_pre_push` test database, and a branch's other migrations fail it with `duplicate_table`",
        "gotcha: the `_pre_push` database is shared by every worktree; another branch's migrations make `mix pre_push` fail with `duplicate_table`"
      ]

      for {item, i} <- Enum.with_index(said) do
        card = card_fixture(ctx.doing, %{"title" => "Card #{i}"})
        {:ok, _} = Boards.add_comment(card, "- Findings:\n  - " <> item, by: ctx.owner)
      end

      assert [%Finding{count: 3, proposal_id: id}] =
               Repo.all(
                 from f in Finding, where: f.board_id == ^ctx.board.id and f.status == "open"
               )

      assert [%Suggestion{id: ^id}] = proposals(ctx.board)
    end

    test "a board without a handbook files nothing", ctx do
      other = board_fixture(%{"name" => "No handbook"}, owner: ctx.owner)
      card = card_fixture(hd(other.columns), %{"title" => "x"})
      f = seen(%{board: other}, card, "a lesson", 5)
      assert Promote.check(f.id) == :skip
      assert proposals(other) == []
    end

    test "a runner's tooling, or a finding no longer open, files nothing", ctx do
      runner = seen(ctx, ctx.ui, "the installed CLI lags", 5, kind: "tooling", scope: "runner")
      done = seen(ctx, ctx.ui, "already settled", 5, status: "dismissed")
      assert Promote.check(runner.id) == :skip
      assert Promote.check(done.id) == :skip
    end
  end

  describe "the page" do
    test "the page whose covers take in the cards' paths, its Rules section", ctx do
      AIStub.fail_with(503, "down")
      {:ok, s} = Promote.check(seen(ctx, ctx.ui, "screens must not flash", 3).id)
      ux = ctx.pages["ux"]
      assert %{"op" => "edit_section", "page" => page_id, "section" => "UX & UI/Rules"} = step(s)
      assert page_id == ux.id
    end

    test "else the Specification page", ctx do
      AIStub.fail_with(503, "down")
      {:ok, s} = Promote.check(seen(ctx, ctx.plain, "every door is tested", 3).id)
      assert step(s)["page"] == ctx.pages["specification"].id
      assert step(s)["body"] =~ "- **SPEC-2** should · judgement · every door is tested"
    end
  end

  describe "the ladder" do
    test "a named test makes a must rule citing it, worded by the model", ctx do
      AIStub.reply_with(%{"text" => "Each screen's first paint is checked by flash_test."})
      text = "screens flash on load; test/app_web/flash_test.exs catches it"
      {:ok, s} = Promote.check(seen(ctx, ctx.ui, text, 3).id)

      assert step(s)["body"] ==
               "- **UX-1** should · judgement · Screens use the layout's header.\n" <>
                 "- **UX-3** must · judgement · LiveViews stream long lists.\n" <>
                 "- **UX-4** must · test/app_web/flash_test.exs · Each screen's first paint is checked by flash_test."

      assert_received {:ai_request, %{"messages" => [_system, %{"content" => prompt}]}}
      assert prompt =~ text
      assert prompt =~ "`must` rule"
      assert prompt =~ "UX-3 must: LiveViews stream long lists."
      assert prompt =~ "##{ctx.ui.id} A screen"
    end

    test "none named makes a should rule by judgement", ctx do
      AIStub.reply_with(%{"text" => "Screens render without a flash of unstyled content."})
      {:ok, s} = Promote.check(seen(ctx, ctx.ui, "screens flash on load", 3).id)

      assert step(s)["body"] =~
               "- **UX-4** should · judgement · Screens render without a flash of unstyled content."
    end

    test "with AI off, a should rule with the finding's text verbatim", ctx do
      AIStub.fail_with(503, "down")
      text = "run `mix format` twice: test/app_web/x_test.exs breaks otherwise"
      {:ok, s} = Promote.check(seen(ctx, ctx.ui, text, 3).id)
      assert step(s)["body"] =~ "- **UX-4** should · judgement · #{text}"
    end

    test "named checks: a test path, a mix command, the repo checks" do
      assert Promote.named_check("see test/slipdock/foo_test.exs") == "test/slipdock/foo_test.exs"

      assert Promote.named_check("`mix format --check-formatted` can fail") ==
               "mix format --check-formatted"

      assert Promote.named_check("it isn't in repo_checks") == "repo_checks"
      assert Promote.named_check("just a habit") == nil
    end
  end

  describe "a person's decision" do
    setup ctx do
      AIStub.fail_with(503, "down")
      f = seen(ctx, ctx.ui, "screens must not flash on load", 3)
      {:ok, s} = Promote.check(f.id)
      %{finding: f, suggestion: s}
    end

    test "accepting promotes the finding with the rule id, and writes the rule", ctx do
      {:ok, _} = Gardener.apply(ctx.suggestion, ctx.owner)

      assert %{status: "promoted", note: note} = Repo.get!(Finding, ctx.finding.id)
      assert note == "UX-4 (proposal ##{ctx.suggestion.id})"

      assert Repo.get!(Page, ctx.pages["ux"].id).body =~
               "- **UX-4** should · judgement · screens must not flash on load"

      # Undoing it opens the finding again, with the proposal open again.
      {:ok, _} = Gardener.undo(Repo.get!(Suggestion, ctx.suggestion.id), ctx.owner)
      assert %{status: "open", note: "proposal #" <> _} = Repo.get!(Finding, ctx.finding.id)
      assert Promote.check(ctx.finding.id) == :skip
    end

    test "dismissing leaves it open with a note, and waits for the threshold again", ctx do
      {:ok, _} = Gardener.dismiss(ctx.suggestion, ctx.owner)
      dismissed = "proposal ##{ctx.suggestion.id} dismissed"
      assert %{status: "open", note: ^dismissed} = Repo.get!(Finding, ctx.finding.id)

      for n <- [4, 5] do
        Repo.update!(Ecto.Changeset.change(Repo.get!(Finding, ctx.finding.id), count: n))
        assert Promote.check(ctx.finding.id) == :skip
      end

      Repo.update!(Ecto.Changeset.change(Repo.get!(Finding, ctx.finding.id), count: 6))
      assert {:ok, %Suggestion{id: again, state: "open"}} = Promote.check(ctx.finding.id)
      assert again != ctx.suggestion.id
      assert %{proposal_id: ^again, proposed_at_count: 6} = Repo.get!(Finding, ctx.finding.id)
    end

    test "Findings shows the proposal on the finding", ctx do
      {:ok, [listed]} = Findings.list(ctx.board)
      assert listed.proposal_id == ctx.suggestion.id and listed.proposed_rule == "UX-4"
    end
  end
end
