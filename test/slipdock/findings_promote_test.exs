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

      for _ <- 1..3, do: {:ok, _} = Boards.Comments.add_comment(ctx.ui, block, by: ctx.owner)

      assert [%Finding{count: 3, proposal_id: id}] =
               Repo.all(from f in Finding, where: f.card_id == ^ctx.ui.id)

      assert [%Suggestion{id: ^id}] = proposals(ctx.board)

      {:ok, _} = Boards.Comments.add_comment(ctx.ui, block, by: ctx.owner)
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
        {:ok, _} = Boards.Comments.add_comment(card, "- Findings:\n  - " <> item, by: ctx.owner)
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

  describe "a finding that names a rule (#2603)" do
    setup ctx do
      write(ctx.pages["data-model"], "[priv/repo/**]", """
      - **DATA-13** should · judgement · Migrations are reversible.
      - **DATA-14** must · judgement · A migration backfills in batches.
      """)

      AIStub.fail_with(503, "down")
      :ok
    end

    test "goes to that rule's page with that page's next id, not the cards' page", ctx do
      text = "DATA-14 migrations time out on a big table"
      finding = seen(ctx, ctx.ui, text, 3)
      {:ok, s} = Promote.check(finding.id)

      assert step(s)["page"] == ctx.pages["data-model"].id
      assert step(s)["section"] == "Data model/Rules"
      assert step(s)["body"] =~ "- **DATA-15** should · judgement · #{text}"
      refute step(s)["body"] =~ "UX-"
      assert Repo.get!(Finding, finding.id).proposed_rule == "DATA-15"
      assert s.explanation =~ "Proposed as DATA-15 on Data model."
    end

    test "a misnumbered rule goes to the page holding it, not the one its prefix names", ctx do
      write(ctx.pages["data-model"], "[priv/repo/**]", """
      - **DATA-14** must · judgement · A migration backfills in batches.
      - **UX-5** should · judgement · Seeds stay small.
      """)

      {:ok, s} = Promote.check(seen(ctx, ctx.ui, "UX-5 seeds grew past a megabyte", 3).id)

      assert step(s)["page"] == ctx.pages["data-model"].id
      assert step(s)["section"] == "Data model/Rules"
      assert step(s)["body"] =~ "- **DATA-15** should"
      refute step(s)["body"] =~ "**UX-4**"
    end

    test "an id no rule holds yet goes to the page its prefix names", ctx do
      {:ok, s} =
        Promote.check(seen(ctx, ctx.plain, "DATA-40 would say: index foreign keys", 3).id)

      assert step(s)["page"] == ctx.pages["data-model"].id
      assert step(s)["body"] =~ "- **DATA-15** should"
    end

    test "the first named page with a Rules section wins", ctx do
      {:ok, _} = Wiki.update_page(ctx.pages["testing"], %{"body" => "# Testing\n\nNo rules.\n"})
      text = "TEST-2 and UX-3 both miss this; see DATA-13"
      {:ok, s} = Promote.check(seen(ctx, ctx.plain, text, 3).id)
      assert step(s)["page"] == ctx.pages["ux"].id
      assert step(s)["body"] =~ "- **UX-4** should"
    end

    test "an id no page answers to falls back to the cards' page", ctx do
      {:ok, s} = Promote.check(seen(ctx, ctx.ui, "CVE-2024 and UTF-8 names break screens", 3).id)
      assert step(s)["page"] == ctx.pages["ux"].id
      assert step(s)["body"] =~ "- **UX-4** should"
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

    test "a rule id in other digits is not a number: the next one counts ASCII ids only", ctx do
      write(ctx.pages["ux"], "[lib/app_web/**]", """
      - **UX-1** should · judgement · Screens use the layout's header.
      - **UX-٣** must · judgement · LiveViews stream long lists.
      """)

      AIStub.fail_with(503, "down")
      {:ok, s} = Promote.check(seen(ctx, ctx.ui, "screens flash on load", 3).id)
      assert step(s)["body"] =~ "- **UX-2** should · judgement · screens flash on load"
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
      {:ok, _} = Gardener.apply(ctx.suggestion, ctx.owner, actor: Slipdock.Actor.web(ctx.owner))

      assert %{status: "promoted", note: note} = Repo.get!(Finding, ctx.finding.id)
      assert note == "UX-4 (proposal ##{ctx.suggestion.id})"

      assert Repo.get!(Page, ctx.pages["ux"].id).body =~
               "- **UX-4** should · judgement · screens must not flash on load"

      # Undoing it opens the finding again, with the proposal open again.
      {:ok, _} =
        Gardener.undo(Repo.get!(Suggestion, ctx.suggestion.id), ctx.owner,
          actor: Slipdock.Actor.web(ctx.owner)
        )

      assert %{status: "open", note: "proposal #" <> _} = Repo.get!(Finding, ctx.finding.id)
      assert Promote.check(ctx.finding.id) == :skip
    end

    test "dismissing leaves it open with a note, and waits for the threshold again", ctx do
      {:ok, _} = Gardener.dismiss(ctx.suggestion, ctx.owner, actor: Slipdock.Actor.web(ctx.owner))
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

    # While its proposal is open the finding waits on the person, out of
    # the open list triage works from (#2767).
    test "Findings shows the proposal on the finding, waiting on it", ctx do
      assert {:ok, []} = Findings.list(ctx.board)
      {:ok, [listed]} = Findings.list(ctx.board, %{"status" => "waiting"})
      assert listed.proposal_id == ctx.suggestion.id and listed.proposed_rule == "UX-4"
      assert listed.waiting == ctx.suggestion.id
    end
  end

  describe "event findings (#2129)" do
    test "health, merge, lane and requeue findings, and other events, draft none", ctx do
      AIStub.fail_with(503, "down")

      for source <- ~w(health merge lane requeue timeout failed incident) do
        f = seen(ctx, ctx.ui, "Lane held, nothing moving (#{source})", 5, source: source)
        assert Promote.check(f.id) == :skip, source
      end

      assert proposals(ctx.board) == []
    end

    test "an agent's, a verifier's and an audit's findings are proposed", ctx do
      AIStub.fail_with(503, "down")
      assert Promote.proposable_sources() == ~w(agent rejection verification audit)

      for source <- Promote.proposable_sources() do
        card = card_fixture(ctx.doing, %{"title" => "From #{source}"})
        f = seen(ctx, card, "a lesson #{source} wrote", 3, source: source)
        assert {:ok, %Suggestion{state: "open"}} = Promote.check(f.id), source
      end

      assert length(proposals(ctx.board)) == 4
    end
  end

  describe "racing drafts (#2129)" do
    # Holds each drafting call until the test says go, so two checks can be
    # past `due/1` at once, as two tasks of a burst of count changes are.
    defp hold_drafts do
      test = self()

      Req.Test.stub(Slipdock.AI, fn conn ->
        send(test, {:drafting, self()})

        receive do
          :go ->
            conn
            |> Plug.Conn.put_status(503)
            |> Req.Test.json(%{"error" => %{"message" => "down"}})
        after
          5_000 -> Plug.Conn.send_resp(conn, 503, "")
        end
      end)
    end

    test "a second count change while the first drafts files no second proposal", ctx do
      hold_drafts()
      f = seen(ctx, ctx.ui, "screens must not flash on load", 3)

      first = Task.async(fn -> Promote.check(f.id) end)
      assert_receive {:drafting, first_draft}

      # The count moves on (a merge into it) while the first still drafts,
      # so the second files under another round.
      Repo.update!(Ecto.Changeset.change(Repo.get!(Finding, f.id), count: 4))
      second = Task.async(fn -> Promote.check(f.id) end)
      assert_receive {:drafting, second_draft}

      send(second_draft, :go)
      assert {:ok, %Suggestion{id: id}} = Task.await(second)

      send(first_draft, :go)
      assert Task.await(first) == :skip

      assert [%Suggestion{id: ^id}] = proposals(ctx.board)
      assert %{proposal_id: ^id, proposed_at_count: 4} = Repo.get!(Finding, f.id)
    end

    test "a finding triaged while its proposal drafts files none", ctx do
      hold_drafts()
      f = seen(ctx, ctx.ui, "screens must not flash on load", 3)

      task = Task.async(fn -> Promote.check(f.id) end)
      assert_receive {:drafting, draft}
      {:ok, _} = Findings.triage(Repo.get!(Finding, f.id), "dismiss", %{"note" => "a one-off"})

      send(draft, :go)
      assert Task.await(task) == :skip
      assert proposals(ctx.board) == []
    end
  end

  describe "triage closes the proposal (#2129)" do
    setup ctx do
      AIStub.fail_with(503, "down")
      f = seen(ctx, ctx.ui, "screens must not flash on load", 3)
      {:ok, s} = Promote.check(f.id)
      %{finding: Repo.get!(Finding, f.id), suggestion: s}
    end

    defp fresh(%Suggestion{id: id}), do: Repo.get!(Suggestion, id)

    defp activity(card) do
      Repo.all(from a in Boards.Activity, where: a.card_id == ^card.id, select: a.message)
      |> Enum.join("\n")
    end

    test "promoting closes it with a note naming why, and reopening opens it again", ctx do
      {:ok, promoted} = Findings.triage(ctx.finding, "promote", %{"note" => "W-1950 §Tests"})

      assert %{state: "dismissed", decided_by_id: nil, decided_at: %DateTime{}, note: note} =
               fresh(ctx.suggestion)

      assert note == "finding ##{ctx.finding.id} promoted: W-1950 §Tests"
      assert Gardener.list_open(ctx.board, check: "proposal") == []

      # The card it is about says so in its activity.
      assert activity(ctx.ui) =~ "proposal ##{ctx.suggestion.id} closed: #{note}"

      {:ok, _} = Findings.triage(promoted, "reopen")
      assert %{state: "open", note: nil, decided_at: nil} = fresh(ctx.suggestion)
      assert activity(ctx.ui) =~ "proposal ##{ctx.suggestion.id} reopened (was closed: #{note})"

      # Open again, it is still the finding's one proposal: no second.
      assert Promote.check(ctx.finding.id) == :skip
      assert length(proposals(ctx.board)) == 1
    end

    test "dismissing closes it, the finding's own note when none is given", ctx do
      Repo.update!(Ecto.Changeset.change(ctx.finding, note: "seen once, long ago"))
      {:ok, _} = Findings.triage(Repo.get!(Finding, ctx.finding.id), "dismiss")

      assert fresh(ctx.suggestion).note ==
               "finding ##{ctx.finding.id} dismissed: seen once, long ago"
    end

    test "merging closes it, naming where it went; the target's own stays open", ctx do
      other = card_fixture(ctx.doing, %{"title" => "Other"})
      into = seen(ctx, other, "screens must never flash", 3)
      {:ok, theirs} = Promote.check(into.id)

      {:ok, _} = Findings.triage(ctx.finding, "merge", %{"into" => into.id})

      assert %{state: "dismissed", note: note} = fresh(ctx.suggestion)
      assert note == "finding ##{ctx.finding.id} merged into ##{into.id}"
      assert fresh(theirs).state == "open"
    end

    test "a dedupe's merge closes the repeat's proposal", ctx do
      Repo.update!(Ecto.Changeset.change(ctx.finding, kind: "gotcha"))
      repeat = seen(ctx, ctx.ui, "screens must not flash on load", 3)
      {:ok, repeat_s} = Promote.check(repeat.id)

      [{%{id: repeat_id}, %{id: into_id}}] = Findings.dedupe(ctx.board)
      assert {repeat_id, into_id} == {repeat.id, ctx.finding.id}

      assert fresh(repeat_s).note =~
               "finding ##{repeat.id} merged into ##{ctx.finding.id}: same lesson"

      assert fresh(ctx.suggestion).state == "open"
    end

    test "duplicates close with it, and only its own proposal reopens", ctx do
      %Suggestion{} = mine = ctx.suggestion

      dupe =
        Repo.insert!(%Suggestion{
          mine
          | id: nil,
            fingerprint: "a duplicate",
            inserted_at: nil,
            updated_at: nil
        })

      {:ok, promoted} = Findings.triage(ctx.finding, "promote", %{"note" => "card #1963"})
      assert Enum.map([ctx.suggestion, dupe], &fresh(&1).state) == ~w(dismissed dismissed)

      {:ok, _} = Findings.triage(promoted, "reopen")
      assert fresh(ctx.suggestion).state == "open"
      assert fresh(dupe).state == "dismissed"
    end

    test "a proposal filed by hand with the finding as evidence stays open", ctx do
      {:ok, by_hand, :new} =
        Gardener.propose(ctx.board, ctx.owner, %{
          "explanation" => "From triage: the lessons that recurred, as rules",
          "steps" => [
            %{
              "op" => "edit_section",
              "page" => ctx.pages["ux"].id,
              "section" => "UX & UI/Rules",
              "body" => "- **UX-9** should · judgement · Screens stay still."
            }
          ],
          "findings" => [ctx.finding.id]
        })

      {:ok, _} = Findings.triage(ctx.finding, "promote", %{"note" => "proposal ##{by_hand.id}"})
      assert fresh(by_hand).state == "open"
      assert fresh(ctx.suggestion).state == "dismissed"
    end

    test "only an open suggestion closes, and only one the server closed reopens", ctx do
      {:ok, dismissed} =
        Gardener.dismiss(ctx.suggestion, ctx.owner, actor: Slipdock.Actor.web(ctx.owner))

      assert {:error, "only an open suggestion can be closed"} = Gardener.close(dismissed, "x")

      assert {:error, "only a suggestion the server closed reopens"} =
               Gardener.reopen_closed(dismissed)

      assert {:error, _} = Gardener.reopen_closed(Repo.get!(Suggestion, ctx.suggestion.id))
    end

    test "a proposal a person dismissed is left as they left it, and not reopened", ctx do
      {:ok, _} = Gardener.dismiss(ctx.suggestion, ctx.owner, actor: Slipdock.Actor.web(ctx.owner))
      finding = Repo.get!(Finding, ctx.finding.id)
      {:ok, promoted} = Findings.triage(finding, "promote", %{"note" => "W-1950"})
      assert %{decided_by_id: decided_by, note: nil} = fresh(ctx.suggestion)
      assert decided_by == ctx.owner.id

      {:ok, _} = Findings.triage(promoted, "reopen")
      assert fresh(ctx.suggestion).state == "dismissed"
    end
  end
end
