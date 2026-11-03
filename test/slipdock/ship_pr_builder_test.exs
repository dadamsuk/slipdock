defmodule Slipdock.ShipPrBuilderTest do
  @moduledoc """
  Ship by PR 2 (#1655): on a board that ships by pull request the builder is
  told, in the claimed job's prompt, to push `card-<id>` and open a pull
  request rather than push the default branch. A push board's prompt is
  unchanged, and verify and merge jobs carry only their own prompt.
  """
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Actor, Boards, Runners, Verified}
  alias Slipdock.Boards.Card

  setup do
    owner = user_fixture("owner@example.com")
    board = board_fixture(%{"name" => "Ships", "code" => unique_code()}, owner: owner)
    [_backlog, todo, doing, _done] = board.columns
    card = card_fixture(todo, %{"title" => ~s(Fix the "login" page)})
    agent = %{Actor.unknown() | kind: "agent", via: "mcp", user_id: owner.id, agent: "bot"}
    %{owner: owner, board: board, todo: todo, doing: doing, card: card, agent: agent}
  end

  defp ship_by_pr(ctx) do
    {:ok, board} =
      Boards.update_board(ctx.board, %{"verify_work" => true, "ship_via" => "pull_request"})

    board
  end

  defp queue(card, kind \\ "claude", prompt \\ "Do it.") do
    {:ok, job} = Runners.queue(card, %{pool: "dev", kind: kind, prompt: prompt})
    job
  end

  test "a push board's claimed prompt is unchanged, and the card has no instructions", ctx do
    {:ok, _} = Boards.update_board(ctx.board, %{"verify_work" => true})
    assert Runners.claimed_prompt(queue(ctx.card)) == "Do it."
    assert Verified.ship_instructions(Repo.get!(Card, ctx.card.id)) == nil
  end

  test "a pull_request board's claimed prompt says to open a PR on card-<id>, never main",
       ctx do
    ship_by_pr(ctx)
    prompt = Runners.claimed_prompt(queue(ctx.card))
    id = ctx.card.id

    assert String.starts_with?(prompt, "Do it.\n\nThis board ships by pull request")
    assert prompt =~ "never push the default branch"
    assert prompt =~ "git push -u origin card-#{id}"
    assert prompt =~ "gh pr view card-#{id}"
    # The title carries the card id, and the card's quotes can't break the command.
    assert prompt =~ ~s[--title "Fix the 'login' page (##{id})"]
    assert prompt =~ "slipdock done #{id} --pr <url>"
    assert prompt =~ "don't merge it yourself"
  end

  test "it comes after the bar and the paths", ctx do
    ship_by_pr(ctx)
    {:ok, card} = Boards.update_card(ctx.card, %{"bar" => "Tests pass", "paths" => ["lib/**"]})
    prompt = Runners.claimed_prompt(queue(card))

    [bar, paths, ship] =
      Enum.map(
        ["card's bar", "card's paths", "ships by pull"],
        &(:binary.match(prompt, &1) |> elem(0))
      )

    assert bar < paths and paths < ship
  end

  test "verify and merge jobs keep their own prompt", ctx do
    ship_by_pr(ctx)
    assert Runners.claimed_prompt(queue(ctx.card, "verify", "Check.")) == "Check."
    assert Runners.claimed_prompt(queue(ctx.card, "merge", "Merge.")) == "Merge."
  end

  test "a rejected card's next attempt is told the same branch, to switch to it", ctx do
    ship_by_pr(ctx)
    first = Verified.ship_instructions(Repo.get!(Card, ctx.card.id))
    pr = "https://github.com/acme/app/pull/7"

    :ok =
      Boards.move_card(ctx.card.id, ctx.doing.id, nil, actor: ctx.agent)

    {:ok, card} =
      Boards.update_card(
        Repo.get!(Card, ctx.card.id),
        %{"completed" => true, "evidence_pr" => pr},
        actor: ctx.agent
      )

    assert card.verify_state == "pending"

    {:ok, rejected} =
      Verified.decide(card, "reject", %{"reason" => "No test"}, Actor.web(ctx.owner), ctx.owner)

    assert rejected.verify_state == "rejected"

    again = Verified.ship_instructions(rejected)
    assert again == first
    assert again =~ "git switch card-#{ctx.card.id}` if it is on origin"
  end

  test "turning verification off ships by push again, and the prompt says nothing", ctx do
    board = ship_by_pr(ctx)
    {:ok, _} = Boards.update_board(board, %{"verify_work" => false})
    assert Runners.claimed_prompt(queue(ctx.card)) == "Do it."
  end
end
