defmodule Slipdock.ShipViaTest do
  @moduledoc """
  Ship by PR 1 (#1654): a board's `ship_via` setting, push by default and
  pull_request only with verification on, and the pull request an agent's
  completion names in `evidence_pr`, which a pull_request board asking for
  evidence requires.
  """
  # Sync: the export/import test derives board codes, as the other import tests.
  use Slipdock.DataCase, async: false

  import Slipdock.Fixtures

  alias Slipdock.{Actor, Boards, Portable, Verified}
  alias Slipdock.Boards.{Board, Card}

  @pr "https://github.com/acme/app/pull/7"

  setup do
    owner = user_fixture("owner@example.com")
    board = board_fixture(%{"name" => "Ships", "code" => unique_code()}, owner: owner)
    [_backlog, _todo, doing, _done] = board.columns
    card = card_fixture(doing, %{"title" => "Work"})
    agent = %{Actor.unknown() | kind: "agent", via: "mcp", user_id: owner.id, agent: "bot"}
    %{owner: owner, board: board, doing: doing, card: card, agent: agent}
  end

  defp pr_board(ctx, extra \\ %{}) do
    {:ok, board} =
      Boards.update_board(
        ctx.board,
        Map.merge(%{"verify_work" => true, "ship_via" => "pull_request"}, extra)
      )

    board
  end

  describe "the setting" do
    test "is push by default, and a push board doesn't ship by PR", ctx do
      assert ctx.board.ship_via == "push"
      refute Board.ships_by_pr?(ctx.board)
    end

    test "pull_request is refused without verification, with the reason", ctx do
      assert {:error, cs} = Boards.update_board(ctx.board, %{"ship_via" => "pull_request"})
      assert %{ship_via: [message]} = errors_on(cs)
      assert message =~ "verify_work"
      assert Boards.get_board!(ctx.board.id).ship_via == "push"
    end

    test "pull_request is taken with verification on, in the same write or after", ctx do
      board = pr_board(ctx)
      assert board.ship_via == "pull_request"
      assert Board.ships_by_pr?(board)
    end

    test "accepts pull-request spelled with a hyphen, and refuses anything else", ctx do
      {:ok, board} =
        Boards.update_board(ctx.board, %{"verify_work" => true, "ship_via" => "Pull-Request"})

      assert board.ship_via == "pull_request"

      assert {:error, cs} = Boards.update_board(board, %{"ship_via" => "carrier-pigeon"})
      assert %{ship_via: ["must be push or pull_request"]} = errors_on(cs)
    end

    test "turning verification off ships by push again", ctx do
      board = pr_board(ctx)
      {:ok, board} = Boards.update_board(board, %{"verify_work" => false})
      assert board.ship_via == "push"
      refute Board.ships_by_pr?(board)
    end

    test "a card's subcards take it, and an export carries it and the PR", ctx do
      board = pr_board(ctx)
      {:ok, t} = Boards.Templates.find_template(nil, "Simple")
      {:ok, sub} = Boards.create_sub_board(Repo.get!(Card, ctx.card.id), t)
      assert sub.ship_via == "pull_request"

      {:ok, _} = Boards.Cards.update_card(Repo.get!(Card, ctx.card.id), %{"evidence_pr" => @pr})

      doc = Portable.export(ctx.owner, boards: [Boards.get_board!(board.id)])
      assert hd(doc.boards).root.ship_via == "pull_request"
      {:ok, report} = Portable.import(ctx.owner, Jason.encode!(doc))
      imported = Boards.get_board!(hd(report.boards).id)
      assert imported.ship_via == "pull_request"
      assert Repo.get_by!(Card, board_id: imported.id, title: "Work").evidence_pr == @pr
    end

    test "an import naming pull_request without verification ships by push", ctx do
      doc = Portable.export(ctx.owner, boards: [Boards.get_board!(ctx.board.id)])
      doc = put_in(doc, [:boards, Access.at(0), :root, :ship_via], "pull_request")
      {:ok, report} = Portable.import(ctx.owner, Jason.encode!(doc))
      assert Boards.get_board!(hd(report.boards).id).ship_via == "push"
    end
  end

  describe "the pull request in evidence" do
    test "must be an http(s) URL", ctx do
      for bad <- ["github.com/acme/app/pull/7", "javascript:alert(1)", "https://x"] do
        assert {:error, cs} = Boards.Cards.update_card(ctx.card, %{"evidence_pr" => bad})
        assert %{evidence_pr: [_]} = errors_on(cs)
      end

      assert {:ok, %{evidence_pr: @pr}} =
               Boards.Cards.update_card(ctx.card, %{"evidence_pr" => "  #{@pr} "})
    end

    test "counts as evidence on its own, and is in the evidence comment", _ctx do
      assert Verified.evidence?(%Card{evidence_pr: @pr})
      assert Verified.evidence_text(%Card{evidence_pr: @pr}) =~ "Pull request: #{@pr}"
    end

    test "a pull_request board asking for evidence refuses an agent's completion without it",
         ctx do
      pr_board(ctx, %{"evidence_required" => true})

      assert {:error, cs} =
               Boards.Cards.update_card(
                 ctx.card,
                 %{"completed" => true, "evidence" => "mix test: 3 passed"},
                 actor: ctx.agent
               )

      assert %{evidence_pr: [message]} = errors_on(cs)
      assert message =~ "--pr"
      refute Repo.get!(Card, ctx.card.id).verify_state

      assert {:ok, %{verify_state: "pending", evidence_pr: @pr}} =
               Boards.Cards.update_card(
                 ctx.card,
                 %{
                   "completed" => true,
                   "evidence" => "mix test",
                   "evidence_pr" => @pr,
                   "evidence_commit" => "abc1234"
                 },
                 actor: ctx.agent
               )
    end

    test "a PR without the commit it merges at is refused, and nothing is stored (#1976)",
         ctx do
      pr_board(ctx, %{"evidence_required" => true})

      assert {:error, cs} =
               Boards.Cards.update_card(
                 ctx.card,
                 %{"completed" => true, "evidence" => "mix test", "evidence_pr" => @pr},
                 actor: ctx.agent
               )

      assert %{evidence_commit: [message]} = errors_on(cs)
      assert message =~ "--evidence-commit"
      assert message =~ "headRefOid"
      card = Repo.get!(Card, ctx.card.id)
      refute card.verify_state
      refute card.completed
      refute card.evidence_pr

      # A blank commit is no commit.
      assert {:error, cs} =
               Boards.Cards.update_card(
                 ctx.card,
                 %{"completed" => true, "evidence_pr" => @pr, "evidence_commit" => "  "},
                 actor: ctx.agent
               )

      assert %{evidence_commit: [_]} = errors_on(cs)
    end

    test "a resubmission after a rejection names its commit again (#1976)", ctx do
      pr_board(ctx, %{"evidence_required" => true})
      submit = %{"completed" => true, "evidence_pr" => @pr, "evidence_commit" => "abc1234"}
      assert {:ok, card} = Boards.Cards.update_card(ctx.card, submit, actor: ctx.agent)

      checker = %{ctx.agent | agent: "checker", via: "api"}

      assert {:ok, card} =
               Verified.decide(
                 card,
                 "reject",
                 %{"reason" => "bar 1: no test"},
                 checker,
                 ctx.owner
               )

      assert card.verify_state == "rejected"
      refute card.evidence_commit

      # The PR alone, as `slipdock done --pr URL` sends it, is refused…
      assert {:error, cs} =
               Boards.Cards.update_card(card, %{"completed" => true, "evidence_pr" => @pr},
                 actor: ctx.agent
               )

      assert %{evidence_commit: [_]} = errors_on(cs)

      # …and with the new head it is pending again, at that commit.
      assert {:ok, %{verify_state: "pending", evidence_commit: "def5678"}} =
               Boards.Cards.update_card(card, %{submit | "evidence_commit" => "def5678"},
                 actor: ctx.agent
               )
    end

    test "a person completing a card with a PR and no commit isn't refused", ctx do
      pr_board(ctx, %{"evidence_required" => true})

      assert {:ok, %{completed: true}} =
               Boards.Cards.update_card(ctx.card, %{"completed" => true, "evidence_pr" => @pr},
                 actor: Actor.web(ctx.owner)
               )
    end

    test "a push board asking for evidence doesn't ask for a PR", ctx do
      {:ok, _} =
        Boards.update_board(ctx.board, %{"verify_work" => true, "evidence_required" => true})

      assert {:ok, %{verify_state: "pending"}} =
               Boards.Cards.update_card(ctx.card, %{"completed" => true, "evidence" => "ran it"},
                 actor: ctx.agent
               )
    end

    test "a person completes a pull_request board's card with no PR", ctx do
      pr_board(ctx, %{"evidence_required" => true})

      assert {:ok, %{completed: true}} =
               Boards.Cards.update_card(ctx.card, %{"completed" => true})
    end
  end
end
