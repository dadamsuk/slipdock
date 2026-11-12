defmodule Slipdock.VerifiedEvidenceTest do
  @moduledoc """
  Verified work 2 (#1632): a board that asks for evidence refuses an agent
  completing a card without saying what it checked — by a write or by a
  move into a done list — keeps the evidence as a comment, and clears it
  when the card is reopened. People, and boards with it off, are untouched.
  """
  # Sync: the export/import test derives board codes, as the other import tests.
  use Slipdock.DataCase, async: false

  import Slipdock.Fixtures

  alias Slipdock.{Actor, Boards, Portable, Verified}
  alias Slipdock.Boards.Card

  setup do
    owner = user_fixture("owner@example.com")
    board = board_fixture(%{"name" => "Evidence", "code" => unique_code()}, owner: owner)
    [_backlog, todo, doing, done] = board.columns
    card = card_fixture(doing, %{"title" => "Work"})
    agent = %{Actor.unknown() | kind: "agent", via: "mcp", user_id: owner.id, agent: "bot"}

    %{
      owner: owner,
      board: board,
      todo: todo,
      doing: doing,
      done: done,
      card: card,
      agent: agent
    }
  end

  defp on(ctx) do
    {:ok, board} = Boards.update_board(ctx.board, %{"evidence_required" => true})
    board
  end

  defp comments(card) do
    Boards.Cards.get_card!(card.id).comments |> Enum.map(& &1.body)
  end

  test "off (the default): an agent completes with no evidence, and nothing is posted", ctx do
    assert Verified.switches(ctx.board) == []

    assert {:ok, %{completed: true}} =
             Boards.Cards.update_card(ctx.card, %{"completed" => true}, actor: ctx.agent)

    {:ok, _} = Boards.Cards.update_card(Repo.get!(Card, ctx.card.id), %{"completed" => false})

    {:ok, _} =
      Boards.Cards.update_card(
        Repo.get!(Card, ctx.card.id),
        %{"completed" => true, "evidence" => "Ran it"},
        actor: ctx.agent,
        by: ctx.owner
      )

    assert comments(ctx.card) == []
  end

  describe "on" do
    setup ctx, do: %{board: on(ctx)}

    test "names itself among the board's switches", ctx do
      assert Verified.switches(ctx.board) == [:evidence]
    end

    test "an agent completing with no evidence is refused, and the card stays open", ctx do
      assert {:error, cs} =
               Boards.Cards.update_card(ctx.card, %{"completed" => true}, actor: ctx.agent)

      assert %{evidence: [message]} = errors_on(cs)
      assert message =~ "required"
      refute Repo.get!(Card, ctx.card.id).completed

      assert {:error, _} =
               Boards.Cards.update_card(ctx.card, %{"completed" => true, "evidence" => "  "},
                 actor: ctx.agent
               )
    end

    test "with evidence and a commit it completes, and the evidence is a comment", ctx do
      assert {:ok, card} =
               Boards.Cards.update_card(
                 ctx.card,
                 %{
                   "completed" => true,
                   "evidence" => "mix test: 12 passed",
                   "evidence_commit" => "abc1234"
                 },
                 actor: ctx.agent,
                 by: ctx.owner
               )

      assert card.completed
      assert card.evidence == "mix test: 12 passed"
      assert card.evidence_commit == "abc1234"
      assert [body] = comments(card)
      assert body =~ "**Evidence.**"
      assert body =~ "mix test: 12 passed"
      assert body =~ "`abc1234`"
    end

    test "evidence written beforehand counts", ctx do
      {:ok, card} =
        Boards.Cards.update_card(ctx.card, %{"evidence" => "Checked the page"}, actor: ctx.agent)

      assert {:ok, %{completed: true}} =
               Boards.Cards.update_card(card, %{"completed" => true}, actor: ctx.agent)
    end

    test "structured evidence counts on its own, is tidied, and is commented in full (#1623)",
         ctx do
      assert {:ok, card} =
               Boards.Cards.update_card(
                 ctx.card,
                 %{
                   "completed" => true,
                   "evidence_commit" => "abc1234",
                   "evidence_branch" => " main ",
                   "evidence_tests" => [
                     " test/a_test.exs",
                     "",
                     "test/a_test.exs",
                     "test/b_test.exs"
                   ],
                   "evidence_suite" => %{result: "passed", passed: 38, failed: 0}
                 },
                 actor: ctx.agent,
                 by: ctx.owner
               )

      assert card.completed
      assert card.evidence_branch == "main"
      assert card.evidence_tests == ["test/a_test.exs", "test/b_test.exs"]
      assert card.evidence_suite == %{"result" => "passed", "passed" => 38, "failed" => 0}

      [body] = comments(card)
      assert body =~ "Commit: `abc1234` on `main`"
      assert body =~ "Suite: passed (38 passed, 0 failed)"
      assert body =~ "- `test/b_test.exs`"

      # Reopened (by a person: an agent can't, #1850), every part is cleared.
      {:ok, card} =
        Boards.Cards.update_card(card, %{"completed" => false}, actor: Actor.web(ctx.owner))

      assert {card.evidence_commit, card.evidence_branch, card.evidence_tests,
              card.evidence_suite} ==
               {nil, nil, nil, nil}
    end

    test "a suite alone is evidence; a malformed one is refused", ctx do
      assert {:ok, %{completed: true}} =
               Boards.Cards.update_card(
                 ctx.card,
                 %{"completed" => true, "evidence_suite" => %{"result" => "failed"}},
                 actor: ctx.agent
               )

      other = card_fixture(ctx.doing, %{"title" => "Other"})

      for bad <- [
            %{"result" => "green"},
            %{"result" => "passed", "passed" => -1},
            %{"passed" => 3}
          ] do
        assert {:error, cs} = Boards.Cards.update_card(other, %{"evidence_suite" => bad})
        assert %{evidence_suite: [_]} = errors_on(cs)
      end

      assert {:error, cs} =
               Boards.Cards.update_card(other, %{"evidence_tests" => [String.duplicate("a", 301)]})

      assert %{evidence_tests: [_]} = errors_on(cs)
    end

    test "the refusal names every field that would do", ctx do
      {:error, cs} = Boards.Cards.update_card(ctx.card, %{"completed" => true}, actor: ctx.agent)
      %{evidence: [message]} = errors_on(cs)

      for field <- ~w(evidence_commit evidence_branch evidence_tests evidence_suite),
          do: assert(message =~ field)
    end

    test "a commit that isn't a commit id is refused", ctx do
      assert {:error, cs} =
               Boards.Cards.update_card(ctx.card, %{
                 "evidence" => "x",
                 "evidence_commit" => "main; rm"
               })

      assert %{evidence_commit: [_]} = errors_on(cs)
    end

    test "an agent moving the card into a done list with no evidence is refused", ctx do
      assert {:error, :unprocessable_entity, message} =
               Boards.Cards.move_card(ctx.card.id, ctx.done.id, nil, actor: ctx.agent)

      assert message =~ "evidence"
      card = Repo.get!(Card, ctx.card.id)
      assert card.column_id == ctx.doing.id
      refute card.completed

      {:ok, _} = Boards.Cards.update_card(card, %{"evidence" => "Ran it"})
      assert :ok = Boards.Cards.move_card(ctx.card.id, ctx.done.id, nil, actor: ctx.agent)
      assert Repo.get!(Card, ctx.card.id).completed
    end

    test "a person, and an automation, complete with no evidence", ctx do
      assert {:ok, %{completed: true}} =
               Boards.Cards.update_card(ctx.card, %{"completed" => true},
                 actor: Actor.web(ctx.owner)
               )

      other = card_fixture(ctx.doing, %{"title" => "Ruled"})
      assert :ok = Boards.Cards.move_card(other.id, ctx.done.id, nil, actor: Actor.automation())
      assert Repo.get!(Card, other.id).completed
    end

    test "reopening clears it, so the next completion needs its own", ctx do
      {:ok, card} =
        Boards.Cards.update_card(
          ctx.card,
          %{"completed" => true, "evidence" => "First", "evidence_commit" => "abcd"},
          actor: ctx.agent
        )

      {:ok, card} =
        Boards.Cards.update_card(card, %{"completed" => false}, actor: Actor.web(ctx.owner))

      assert card.evidence == nil and card.evidence_commit == nil

      assert {:error, _} =
               Boards.Cards.update_card(card, %{"completed" => true}, actor: ctx.agent)
    end

    test "a card's subcards take the switch, and an export carries it and the evidence", ctx do
      {:ok, t} = Boards.Templates.find_template(nil, "Simple")
      {:ok, sub} = Boards.create_sub_board(ctx.card, t)
      assert sub.evidence_required

      {:ok, _} =
        Boards.Cards.update_card(ctx.card, %{
          "evidence" => "Ran it",
          "evidence_commit" => "abc1234",
          "evidence_no_code" => "a sweep (#1938)"
        })

      doc = Portable.export(ctx.owner, boards: [Boards.get_board!(ctx.board.id)])
      [tree] = doc.boards
      assert tree.root.evidence_required

      {:ok, report} = Portable.import(ctx.owner, Jason.encode!(doc))
      imported = Boards.get_board!(hd(report.boards).id)
      assert imported.evidence_required
      copy = Repo.get_by!(Card, board_id: imported.id, title: "Work")
      assert copy.evidence == "Ran it" and copy.evidence_commit == "abc1234"
      assert copy.evidence_no_code == "a sweep (#1938)"
    end
  end
end
