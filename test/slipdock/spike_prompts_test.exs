defmodule Slipdock.SpikePromptsTest do
  @moduledoc """
  Building and verifying a spike (#2351): a spike's build prompt (its ship
  instructions) says to prototype on `card-<id>`, push it, never open a pull
  request, pin the answer page to the epic and complete with `--no-code`,
  on any board; its verify prompt judges the answer, the evidence and what
  it changes, passes *inconclusive*, and runs no suite unless the bar asks.
  A card that isn't a spike gets what it got before.
  """
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Actor, Boards, Repo, Verified}
  alias Slipdock.Boards.{Board, Card}

  setup do
    owner = user_fixture()
    board = board_fixture(%{"name" => "Spike prompts", "code" => unique_code()}, owner: owner)

    {:ok, board} =
      Boards.update_board(board, %{
        "verify_work" => true,
        "evidence_required" => true,
        "ship_via" => "pull_request"
      })

    [_backlog, _todo, doing, _done] = board.columns
    builder = %{Actor.unknown() | kind: "agent", via: "api", user_id: owner.id, agent: "builder"}
    %{owner: owner, board: board, doing: doing, builder: builder}
  end

  defp spike(ctx) do
    card = card_fixture(ctx.doing, %{"title" => "Does the API page?"})
    {:ok, card} = Boards.update_card(card, %{"profile" => "spike"})
    Repo.get!(Card, card.id)
  end

  describe "the build prompt" do
    test "a spike's says branch, no PR, the answer page and --no-code", ctx do
      card = spike(ctx)
      text = Verified.ship_instructions(card)

      assert text =~ "This card is a spike"
      assert text =~ "`card-#{card.id}`"
      assert text =~ "never open a pull request"
      assert text =~ "pin it to the epic"
      assert text =~ "what the answer changes in the plan"
      assert text =~ "*inconclusive*"
      assert text =~ "Findings:"
      assert text =~ "slipdock done #{card.id} --no-code \"spike: answer on W-…"
      refute text =~ "gh pr create"
      refute text =~ "--pr <url>"
    end

    test "a spike gets it on a board that ships by push too", ctx do
      {:ok, _} = Boards.update_board(ctx.board, %{"ship_via" => "push"})
      text = Verified.ship_instructions(spike(ctx))
      assert text =~ "This card is a spike"
      assert text =~ "Never push the default branch"
    end

    test "a hand-tagged spike gets it", ctx do
      card = card_fixture(ctx.doing, %{"title" => "Tagged"})
      {:ok, _} = Boards.set_card_tags(card, [tag_fixture(ctx.board, "spike")])
      assert Verified.ship_instructions(Repo.get!(Card, card.id)) =~ "This card is a spike"
    end

    test "a card that isn't a spike keeps the pull request instructions", ctx do
      card = Repo.get!(Card, card_fixture(ctx.doing, %{"title" => "Feature"}).id)
      text = Verified.ship_instructions(card)
      assert text =~ "This board ships by pull request"
      assert text =~ "gh pr create"
      refute text =~ "This card is a spike"

      {:ok, _} = Boards.update_board(ctx.board, %{"ship_via" => "push"})
      assert Verified.ship_instructions(Repo.get!(Card, card.id)) == nil
    end
  end

  describe "the verify prompt" do
    test "a spike's judges the answer and its evidence, and runs no suite", ctx do
      card = spike(ctx)

      {:ok, card} =
        Boards.update_card(
          card,
          %{
            "completed" => true,
            "evidence" => "p95 420 ms over 10k rows",
            "evidence_no_code" => "spike: answer on W-9, prototype on card-#{card.id}"
          },
          actor: ctx.builder
        )

      prompt = Verified.verify_prompt(card, Repo.get!(Board, card.board_id))

      assert prompt =~ "This card is a spike"
      assert prompt =~ "spike: answer on W-9, prototype on card-#{card.id}"
      assert prompt =~ "don't run the suite unless the bar asks for one"
      assert prompt =~ "The ask: the answer addresses the question"
      assert prompt =~ "The evidence is real"
      assert prompt =~ "what the answer changes in the plan"
      assert prompt =~ "*Inconclusive*, with what was learned, passes"
      assert prompt =~ "Reject only for not really trying, or for an answer without evidence"
      refute prompt =~ "Run the suite"
      refute prompt =~ "gh pr view"
    end

    test "it names the evidence's branch, else card-<id>", ctx do
      card = spike(ctx)
      why = "spike: answer on W-9"

      {:ok, named} =
        Boards.update_card(
          card,
          %{
            "completed" => true,
            "evidence" => "built it",
            "evidence_no_code" => why,
            "evidence_branch" => "spike/paging-probe"
          },
          actor: ctx.builder
        )

      prompt = Verified.verify_prompt(named, Repo.get!(Board, named.board_id))
      assert prompt =~ "the prototype on `spike/paging-probe`"
      refute prompt =~ "the prototype on `card-#{card.id}`"

      other = spike(ctx)

      {:ok, blank} =
        Boards.update_card(
          other,
          %{"completed" => true, "evidence" => "built it", "evidence_no_code" => why},
          actor: ctx.builder
        )

      assert blank.evidence_branch in [nil, ""]
      prompt = Verified.verify_prompt(blank, Repo.get!(Board, blank.board_id))
      assert prompt =~ "the prototype on `card-#{other.id}`"
    end

    test "a card that isn't a spike gets the no-code step as before", ctx do
      card = card_fixture(ctx.doing, %{"title" => "Sweep"})

      {:ok, card} =
        Boards.update_card(
          card,
          %{"completed" => true, "evidence" => "swept", "evidence_no_code" => "a sweep"},
          actor: ctx.builder
        )

      prompt = Verified.verify_prompt(card, Repo.get!(Board, card.board_id))
      assert prompt =~ "The builder says this card changes no code"
      refute prompt =~ "This card is a spike"
    end
  end
end
