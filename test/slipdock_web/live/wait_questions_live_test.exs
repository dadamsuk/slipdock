defmodule SlipdockWeb.WaitQuestionsLiveTest do
  @moduledoc """
  Follow-up questions in the card panel (#1220): a series numbered with a
  box each, answering them, a suggested answer from the reader's model,
  Skip, asking questions from the card, and the questions asked before.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Access, Actor, AIStub, Boards}
  alias Slipdock.Boards.Wait

  setup %{user: owner} do
    board = board_fixture(%{}, owner: owner)
    card = card_fixture(hd(board.columns), %{"title" => "Deploy", "description" => "Ship to eu"})
    %{board: board, card: card, owner: owner}
  end

  defp open(conn, ctx), do: live(conn, ~p"/boards/#{ctx.board}/cards/#{ctx.card.id}")

  defp ask(ctx, attrs \\ %{"questions" => ["Which region?", "How many seats?"]}) do
    agent = %{Actor.unknown() | kind: "agent", via: "mcp", user_id: ctx.owner.id, agent: "claude"}
    {:ok, wait} = Boards.open_wait(ctx.card, agent, attrs)
    wait
  end

  describe "a series" do
    test "is numbered, with a box for each question", ctx do
      ask(ctx)
      {:ok, view, _} = open(ctx.conn, ctx)

      assert has_element?(view, "#wait-needs", "2 questions: Which region?")
      assert has_element?(view, "#wait-question-1", "1.")
      assert has_element?(view, "#wait-question-1", "Which region?")
      assert has_element?(view, "#wait-question-2", "How many seats?")
      assert has_element?(view, "#wait-answer-1")
      assert has_element?(view, "#wait-answer-2")
      assert has_element?(view, "#wait-answer", "Send answers")
    end

    test "a single question has one box and no number", ctx do
      ask(ctx, %{"needs" => "Which region?"})
      {:ok, view, _} = open(ctx.conn, ctx)

      assert has_element?(view, "#wait-answer-1")
      refute has_element?(view, "#wait-answer-2")
      refute has_element?(view, "#wait-question-1", "1.")
      assert has_element?(view, "#wait-answer", "Answer")
    end

    test "sending the boxes answers each question, as the person", ctx do
      ask(ctx)
      {:ok, view, _} = open(ctx.conn, ctx)

      view
      |> form("#wait-answer-form", %{"wait" => %{"answers" => %{"1" => "eu", "2" => "12"}}})
      |> render_submit()

      assert %{close_reason: "answered", answers: ["eu", "12"], closed_by_id: id} =
               Boards.last_wait(ctx.card)

      assert id == ctx.owner.id
      refute has_element?(view, "#card-wait")
    end

    test "with every box empty it says so and stays open", ctx do
      ask(ctx)
      {:ok, view, _} = open(ctx.conn, ctx)

      view
      |> form("#wait-answer-form", %{"wait" => %{"answers" => %{"1" => "", "2" => ""}}})
      |> render_submit()

      assert render(view) =~ "an answer needs text or a choice"
      assert Wait.open?(Boards.current_wait(ctx.card))
    end

    test "a reader sees the numbered questions but no boxes", ctx do
      reader = user_fixture("questions.reader@example.com")
      {:ok, _} = Access.grant(ctx.board, reader, "read", ctx.owner)
      ask(ctx)

      {:ok, view, _} = open(log_in_user(build_conn(), reader), ctx)
      assert has_element?(view, "#wait-questions", "How many seats?")
      refute has_element?(view, "#wait-answer-form")
      refute has_element?(view, "#wait-skip")
    end
  end

  describe "Skip" do
    test "closes the wait as skipped and the panel goes", ctx do
      ask(ctx)
      {:ok, view, _} = open(ctx.conn, ctx)

      view |> element("#wait-skip") |> render_click()

      assert %{close_reason: "skipped"} = Boards.last_wait(ctx.card)
      refute has_element?(view, "#card-wait")
      refute "waiting" in Boards.get_card!(ctx.card.id).flags
    end
  end

  describe "suggesting an answer" do
    test "fills that box from the model, keeps what was typed in the others, and sends nothing",
         ctx do
      AIStub.reply_with(%{"answer" => "eu-west-1"})
      ask(ctx)
      {:ok, view, _} = open(ctx.conn, ctx)

      view
      |> form("#wait-answer-form", %{"wait" => %{"answers" => %{"1" => "", "2" => "12"}}})
      |> render_change()

      view |> element("#wait-suggest-1") |> render_click()
      render_async(view)

      assert has_element?(view, "#wait-answer-1", "eu-west-1")
      assert has_element?(view, "#wait-answer-2", "12")
      assert Wait.open?(Boards.current_wait(ctx.card))

      assert_received {:ai_request, %{"messages" => [_, %{"content" => content}]}}
      assert content =~ "Ship to eu"
      assert content =~ "1. Which region? ← answer this one"
      assert content =~ "2. How many seats?\n   (answered: 12)"
    end

    test "says why when the model gives nothing", ctx do
      AIStub.reply_with(%{"nope" => true})
      ask(ctx)
      {:ok, view, _} = open(ctx.conn, ctx)

      view |> element("#wait-suggest-2") |> render_click()
      render_async(view)

      assert has_element?(view, "#wait-suggest-error-2", "didn't suggest an answer")
    end

    test "is not offered without a model, and the event asks none", ctx do
      Slipdock.TestConfig.merge(:ai, api_key: nil)
      ask(ctx)
      {:ok, view, _} = open(ctx.conn, ctx)

      refute has_element?(view, "#wait-suggest-1")

      view |> with_target("#board-card") |> render_click("suggest_answer", %{"n" => "1"})
      refute_received {:ai_request, _}
      assert render(view) =~ "Suggesting needs an AI model"
    end
  end

  describe "asking questions" do
    test "the meta line offers it; the form asks a numbered series of someone", ctx do
      dana = user_fixture("questions.dana@example.com")
      {:ok, _} = Access.grant(ctx.board, dana, "write", ctx.owner)
      {:ok, view, _} = open(ctx.conn, ctx)

      view |> element("#wait-ask") |> render_click()
      assert has_element?(view, "#wait-ask-1")
      refute has_element?(view, "#wait-ask-remove-1")

      view |> element("#wait-ask-add") |> render_click()
      assert has_element?(view, "#wait-ask-2")

      view
      |> form("#wait-ask-form", %{
        "ask" => %{"questions" => %{"1" => "Which region?", "2" => "Budget?"}, "on" => dana.id}
      })
      |> render_submit()

      wait = Boards.current_wait(ctx.card)
      assert wait.questions == ["Which region?", "Budget?"]
      assert wait.on_user_id == dana.id
      assert {wait.kind, wait.opened_by_id} == {"human", ctx.owner.id}
      assert "waiting" in Boards.get_card!(ctx.card.id).flags
      assert has_element?(view, "#wait-question-2", "Budget?")
      refute has_element?(view, "#wait-ask")
    end

    test "removing a question renumbers the rest; Cancel asks nothing", ctx do
      {:ok, view, _} = open(ctx.conn, ctx)
      view |> element("#wait-ask") |> render_click()
      view |> element("#wait-ask-add") |> render_click()

      view
      |> form("#wait-ask-form", %{"ask" => %{"questions" => %{"1" => "A?", "2" => "B?"}}})
      |> render_change()

      view |> element("#wait-ask-remove-1") |> render_click()
      assert has_element?(view, "#wait-ask-1", "B?")
      refute has_element?(view, "#wait-ask-2")

      view |> element("#wait-ask-cancel") |> render_click()
      refute has_element?(view, "#wait-ask-form")
      assert Boards.current_wait(ctx.card) == nil
    end

    test "no question at all is refused, and the form stays", ctx do
      {:ok, view, _} = open(ctx.conn, ctx)
      view |> element("#wait-ask") |> render_click()

      view
      |> form("#wait-ask-form", %{"ask" => %{"questions" => %{"1" => " "}}})
      |> render_submit()

      assert render(view) =~ "say what you need"
      assert has_element?(view, "#wait-ask-form")
      assert Boards.current_wait(ctx.card) == nil
    end

    test "not offered while a wait is open, nor to a reader", ctx do
      reader = user_fixture("questions.reader2@example.com")
      {:ok, _} = Access.grant(ctx.board, reader, "read", ctx.owner)

      {:ok, view, _} = open(log_in_user(build_conn(), reader), ctx)
      refute has_element?(view, "#wait-ask")

      ask(ctx)
      {:ok, view, _} = open(ctx.conn, ctx)
      refute has_element?(view, "#wait-ask")
    end
  end

  describe "questions asked before" do
    test "lists each with its answers, who closed it and how", ctx do
      ask(ctx)
      {:ok, _} = Boards.answer_wait(ctx.card, Actor.web(ctx.owner), %{"answers" => ["eu"]})
      ask(ctx, %{"needs" => "Ready to ship?"})
      {:ok, _} = Boards.answer_wait(ctx.card, Actor.web(ctx.owner), %{"skip" => true})
      [skipped, answered] = Boards.list_waits(ctx.card)

      {:ok, view, _} = open(ctx.conn, ctx)

      assert has_element?(view, "#card-wait-history summary", "Questions asked before (2)")
      assert has_element?(view, "#wait-history-#{answered.id}", "1. Which region?")
      assert has_element?(view, "#wait-history-#{answered.id}", "→ eu")
      assert has_element?(view, "#wait-history-#{answered.id}", "(not answered)")
      assert has_element?(view, "#wait-history-#{answered.id}", "answered by")
      assert has_element?(view, "#wait-history-#{skipped.id}", "Ready to ship?")
      assert has_element?(view, "#wait-history-#{skipped.id}", "skipped by")
    end

    test "an open wait is not in it, and a card that never asked has none", ctx do
      {:ok, view, _} = open(ctx.conn, ctx)
      refute has_element?(view, "#card-wait-history")

      ask(ctx)
      {:ok, view, _} = open(ctx.conn, ctx)
      refute has_element?(view, "#card-wait-history")
    end
  end
end
