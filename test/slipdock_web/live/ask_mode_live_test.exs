defmodule SlipdockWeb.AskModeLiveTest do
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Boards, Search}

  setup %{user: user} do
    Slipdock.AIStub.stub_embeddings()

    board = board_fixture(%{"name" => "Delivery"}, owner: user)
    card = card_fixture(hd(board.columns), %{"title" => "Invoice rounding is wrong on refunds"})
    {:ok, _} = Boards.add_comment(card, "finance want this before the audit")
    {:ok, _} = Search.index_cards(Search.load_cards(Search.all_card_ids()))

    %{board: board, card: card}
  end

  test "the empty page offers questions to start from", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/ask")
    assert html =~ "What&#39;s at risk across all my boards right now?"
    assert html =~ "It can read, not write"
    assert html =~ "Search finds cards; Ask gives answers to questions."
  end

  test "asking searches, answers, and shows both the searches and the sources", ctx do
    Slipdock.AIStub.reply_sequence([
      {:tool_calls, [{"search_cards", %{"query" => "invoice rounding refunds"}}]},
      "The **refund rounding** card is the one, and finance are waiting on it."
    ])

    {:ok, view, _html} = live(ctx.conn, ~p"/ask")

    view
    |> form("#deep-search", %{"q" => "What's happening with refunds?"})
    |> render_submit()

    assert render(view) =~ "What&#39;s happening with refunds?"

    html = render_async(view)
    assert html =~ "<strong>refund rounding</strong> card is the one"
    # What it searched for, so the answer can be judged.
    assert html =~ "invoice rounding refunds"
    # And what it read, as links.
    assert html =~ "1 thing it looked at"
    assert html =~ "/boards/#{ctx.board.id}/cards/#{ctx.card.id}"
  end

  test "a suggestion asks itself", ctx do
    Slipdock.AIStub.reply_with("Nothing is at risk.")
    {:ok, view, _html} = live(ctx.conn, ~p"/ask")

    view
    |> element("button", "What's at risk across all my boards right now?")
    |> render_click()

    assert render_async(view) =~ "Nothing is at risk."
  end

  test "a question in the URL is asked on arrival — this is where /search hands over", ctx do
    Slipdock.AIStub.reply_with("Here's what I found.")
    {:ok, view, _html} = live(ctx.conn, ~p"/ask?#{[q: "what about refunds"]}")

    html = render_async(view)
    assert html =~ "what about refunds"
    assert html =~ "Here&#39;s what I found."
  end

  test "a model error is shown rather than swallowed", ctx do
    Slipdock.AIStub.fail_with(402, "out of credit")
    {:ok, view, _html} = live(ctx.conn, ~p"/ask")

    view |> form("#deep-search", %{"q" => "Anything?"}) |> render_submit()
    assert render_async(view) =~ "no credit left"
  end

  test "starting again empties the conversation", ctx do
    Slipdock.AIStub.reply_with("An answer.")
    {:ok, view, _html} = live(ctx.conn, ~p"/ask")

    view |> form("#deep-search", %{"q" => "A question"}) |> render_submit()
    assert render_async(view) =~ "An answer."

    view |> element("button[phx-click=reset]") |> render_click()
    html = render(view)
    refute html =~ "An answer."
    assert html =~ "It can read, not write"
  end

  test "an empty question does nothing", ctx do
    {:ok, view, _html} = live(ctx.conn, ~p"/ask")
    view |> form("#deep-search", %{"q" => "   "}) |> render_submit()
    assert render(view) =~ "It can read, not write"
  end

  test "typing in Ask does not fire a model call — only Enter does", ctx do
    {:ok, view, _html} = live(ctx.conn, ~p"/ask")
    view |> form("#deep-search") |> render_change(%{"q" => "half a thou"})
    refute_receive {:ai_request, _}, 100
  end

  describe "saving a question" do
    test "each question in the thread has a star, since the box clears on submit", ctx do
      Slipdock.AIStub.reply_with("An answer.")
      {:ok, view, _html} = live(ctx.conn, ~p"/ask")

      view |> form("#deep-search", %{"q" => "what about refunds"}) |> render_submit()
      assert render_async(view) =~ "An answer."

      # The box emptied itself, so its own star is gone…
      refute has_element?(view, "form#deep-search button[phx-click=toggle_saved]")
      # …and the question carries one instead.
      assert has_element?(view, "button[phx-click=toggle_saved][aria-pressed=false]")

      view |> element("button[phx-click=toggle_saved]") |> render_click()

      assert has_element?(view, "button[phx-click=toggle_saved][aria-pressed=true]")

      assert [%{text: "what about refunds", mode: "ask"}] =
               Slipdock.SavedQueries.list(ctx.user, "ask")
    end

    test "pressing a saved question's star again unsaves it", ctx do
      {:ok, _} = Slipdock.SavedQueries.save(ctx.user, "ask", "what about refunds")
      Slipdock.AIStub.reply_with("An answer.")
      {:ok, view, _html} = live(ctx.conn, ~p"/ask")

      view |> form("#deep-search", %{"q" => "what about refunds"}) |> render_submit()
      render_async(view)

      assert has_element?(view, "button[phx-click=toggle_saved][aria-pressed=true]")
      view |> element("button[phx-click=toggle_saved]") |> render_click()
      assert Slipdock.SavedQueries.list(ctx.user, "ask") == []
    end

    test "a saved question replaces the samples on the next visit", ctx do
      Slipdock.AIStub.reply_with("An answer.")
      {:ok, view, _html} = live(ctx.conn, ~p"/ask")

      view |> form("#deep-search", %{"q" => "what about refunds"}) |> render_submit()
      render_async(view)
      view |> element("button[phx-click=toggle_saved]") |> render_click()

      {:ok, _view, html} = live(ctx.conn, ~p"/ask")
      assert html =~ "Saved questions"
      assert html =~ "what about refunds"
      refute html =~ "What&#39;s at risk across all my boards right now?"
    end

    test "a question saved in Ask does not appear in Search", ctx do
      {:ok, _} = Slipdock.SavedQueries.save(ctx.user, "ask", "what about refunds")

      {:ok, _view, html} = live(ctx.conn, ~p"/search")
      refute html =~ "what about refunds"
      assert html =~ "anything about flaky tests"
    end
  end

  test "a stranger's question finds none of this user's cards" do
    stranger = user_fixture("stranger@example.com")

    Slipdock.AIStub.reply_sequence([
      {:tool_calls, [{"search_cards", %{"query" => "invoice rounding refunds"}}]},
      "I couldn't find anything."
    ])

    {:ok, view, _html} = live(conn_as(stranger), ~p"/ask")
    view |> form("#deep-search", %{"q" => "Anything about refunds?"}) |> render_submit()

    html = render_async(view)
    assert html =~ "couldn&#39;t find anything"
    refute html =~ "Invoice rounding is wrong on refunds"
    refute html =~ "card it looked at"
  end
end
