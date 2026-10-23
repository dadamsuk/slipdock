defmodule Slipdock.AIWaitAnswererTest do
  @moduledoc """
  A suggested answer to one of a wait's questions (#1220): what the model
  is told (the card, every question with the one to answer marked, what is
  already typed, any choices) and what is made of its answer.
  """
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Actor, AIStub, Boards}
  alias Slipdock.AI.WaitAnswerer

  setup do
    owner = user_fixture()
    board = board_fixture(%{}, owner: owner)

    card =
      card_fixture(hd(board.columns), %{"title" => "Deploy", "description" => "Region: eu"})

    %{owner: owner, board: board, card: card}
  end

  defp ask(ctx, attrs) do
    {:ok, wait} = Boards.open_wait(ctx.card, Actor.web(ctx.owner), attrs)
    wait
  end

  defp loaded(ctx), do: Boards.get_card!(ctx.card.id)

  test "suggests the answer to question n, told the card and the questions", ctx do
    AIStub.reply_with(%{"answer" => "  eu-west-1 "})
    wait = ask(ctx, %{"needs" => "Before deploy", "questions" => ["Which region?", "Seats?"]})

    assert {:ok, "eu-west-1"} =
             WaitAnswerer.suggest(loaded(ctx), ctx.board, wait, 1, %{2 => "12"}, user: ctx.owner)

    assert_received {:ai_request, %{"messages" => [_, %{"content" => content}]}}
    assert content =~ "Region: eu"
    assert content =~ "Before deploy"
    assert content =~ "1. Which region? ← answer this one"
    assert content =~ "2. Seats?\n   (answered: 12)"
  end

  test "a single question with choices: the choices are in the context", ctx do
    wait = ask(ctx, %{"needs" => "Which region?", "choices" => ["eu", "us"]})
    text = WaitAnswerer.context(loaded(ctx), ctx.board, wait, 1)

    assert text =~ "1. Which region? ← answer this one"
    assert text =~ "The asker offered these choices: eu; us"
  end

  test "no answer from the model, or a blank one, is an error to show", ctx do
    wait = ask(ctx, %{"needs" => "Which region?"})

    AIStub.reply_with(%{"answer" => "  "})

    assert {:error, "The model didn't suggest an answer." <> _} =
             WaitAnswerer.suggest(loaded(ctx), ctx.board, wait, 1, %{}, user: ctx.owner)

    AIStub.reply_with(%{"something" => "else"})

    assert {:error, "The model didn't suggest an answer." <> _} =
             WaitAnswerer.suggest(loaded(ctx), ctx.board, wait, 1, %{}, user: ctx.owner)
  end

  test "a question that isn't there asks no model", ctx do
    wait = ask(ctx, %{"needs" => "Which region?"})

    assert {:error, "There is no question 2 to answer."} =
             WaitAnswerer.suggest(loaded(ctx), ctx.board, wait, 2, %{}, user: ctx.owner)

    refute_received {:ai_request, _}
  end
end
