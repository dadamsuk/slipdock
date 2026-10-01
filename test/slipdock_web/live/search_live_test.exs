defmodule SlipdockWeb.SearchLiveTest do
  use SlipdockWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Access, Boards, Search}

  setup %{user: user} do
    Slipdock.AIStub.share()
    Slipdock.AIStub.stub_embeddings()

    board = board_fixture(%{"name" => "Delivery"}, owner: user)
    column = hd(board.columns)

    refunds = card_fixture(column, %{"title" => "Invoice rounding is wrong on refunds"})
    deploy = card_fixture(column, %{"title" => "Deploy pipeline needs a rollback step"})
    {:ok, _} = Boards.add_comment(deploy, "the staging rollback was blocked on approvals")

    {:ok, _} = Search.index_cards(Search.load_cards(Search.all_card_ids()))

    %{board: board, column: column, refunds: refunds, deploy: deploy}
  end

  test "the empty page invites a description rather than a keyword", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/search")
    assert html =~ "the card that was blocked on legal"
    assert html =~ "Describe what you&#39;re after rather than guessing at its title"
    assert html =~ "Search finds cards; Ask gives answers to questions."
    refute html =~ "Nothing is indexed yet"
  end

  test "both modes are one page, and the toggle says which you are in", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/search")
    assert has_element?(view, "[role=tab][aria-selected=true]", "Search")
    assert has_element?(view, "[role=tab][aria-selected=false]", "Ask")

    {:ok, view, _html} = live(conn, ~p"/ask")
    assert has_element?(view, "[role=tab][aria-selected=true]", "Ask")
    assert has_element?(view, "[role=tab][aria-selected=false]", "Search")
  end

  test "the toggle carries the query across, and keeps each mode's own state", ctx do
    {:ok, view, _html} = live(ctx.conn, ~p"/search")
    view |> form("#deep-search") |> render_change(%{"q" => "invoice rounding refunds"})
    assert render_async(view) =~ "Invoice rounding is wrong on refunds"

    # Ask is one click away with the question already in the box.
    Slipdock.AIStub.reply_with("Here is an answer.")
    view |> element("[role=tab]", "Ask") |> render_click()
    assert render_async(view) =~ "Here is an answer."

    # And the results are still there on the way back — no second search.
    view |> element("[role=tab]", "Search") |> render_click()
    assert render(view) =~ "Invoice rounding is wrong on refunds"
  end

  test "an index nobody has built says so, rather than answering nothing found" do
    Slipdock.Search.clear()
    conn = conn_as(user_fixture("fresh@example.com"))

    {:ok, _view, html} = live(conn, ~p"/search")
    assert html =~ "Nothing is indexed yet"
    assert html =~ "every search comes back empty"
    assert html =~ "mix slipdock.reindex"

    {:ok, _view, html} = live(conn, ~p"/ask")
    assert html =~ "the assistant has nothing to search"
  end

  test "searching shows the card, where it lives and why it matched", ctx do
    {:ok, view, _html} = live(ctx.conn, ~p"/search")

    view |> form("#deep-search") |> render_change(%{"q" => "invoice rounding refunds"})
    html = render_async(view)

    assert html =~ "Invoice rounding is wrong on refunds"
    assert html =~ "Delivery"
    assert html =~ "Strong"
  end

  test "a comment is what brings its card back, and the snippet says so", ctx do
    {:ok, view, _html} = live(ctx.conn, ~p"/search")

    view |> form("#deep-search") |> render_change(%{"q" => "staging rollback blocked approvals"})
    html = render_async(view)

    assert html =~ "Deploy pipeline needs a rollback step"
    assert html =~ "comment"
    assert html =~ "staging rollback was blocked"
    # The chunk's "Comment on card …" preamble is for the model, not the reader.
    refute html =~ "Comment on card"
  end

  test "a query in the URL runs on mount", ctx do
    {:ok, view, _html} = live(ctx.conn, ~p"/search?#{[q: "invoice rounding refunds"]}")
    assert render_async(view) =~ "Invoice rounding is wrong on refunds"
  end

  test "a board in the URL narrows the search to it", ctx do
    other = board_fixture(%{"name" => "Marketing"}, owner: ctx.user)
    elsewhere = card_fixture(hd(other.columns), %{"title" => "Invoice rounding on refunds too"})
    {:ok, _} = Search.index_cards(Search.load_cards([elsewhere.id]))

    {:ok, view, _html} =
      live(ctx.conn, ~p"/search?#{[q: "invoice rounding refunds", board: ctx.board.id]}")

    html = render_async(view)
    assert html =~ "Invoice rounding is wrong on refunds"
    refute html =~ "Invoice rounding on refunds too"
  end

  test "a board the reader cannot open is not a scope they can ask for", ctx do
    stranger = user_fixture("stranger@example.com")
    theirs = board_fixture(%{"name" => "Secret"}, owner: stranger)

    {:ok, view, _html} =
      live(ctx.conn, ~p"/search?#{[q: "invoice rounding refunds", board: theirs.id]}")

    # Ignored rather than obeyed: the search runs across what they can see.
    assert render_async(view) =~ "Invoice rounding is wrong on refunds"
  end

  test "nothing close enough says so", ctx do
    {:ok, view, _html} = live(ctx.conn, ~p"/search")
    view |> form("#deep-search") |> render_change(%{"q" => "zebra xylophone quokka"})
    assert render_async(view) =~ "Nothing close enough"
  end

  describe "saving a query" do
    test "the star saves what is in the box, and the saved list replaces the examples", ctx do
      {:ok, view, html} = live(ctx.conn, ~p"/search")
      assert html =~ "anything about flaky tests"
      refute html =~ "Saved searches"

      view |> form("#deep-search") |> render_change(%{"q" => "invoice rounding refunds"})
      render_async(view)
      view |> element("button[phx-click=toggle_saved]") |> render_click()

      # The star goes gold; the list itself is behind the results until the
      # box is empty again.
      assert has_element?(view, "button[phx-click=toggle_saved][aria-pressed=true]")

      assert [%{text: "invoice rounding refunds"}] =
               Slipdock.SavedQueries.list(ctx.user, "search")

      # And the examples are gone: your own questions are the better examples.
      {:ok, _view, html} = live(ctx.conn, ~p"/search")
      assert html =~ "Saved searches"
      assert html =~ "invoice rounding refunds"
      refute html =~ "anything about flaky tests"
    end

    test "the star shows what is already saved, and unsaves on a second press", ctx do
      {:ok, _} = Slipdock.SavedQueries.save(ctx.user, "search", "invoice rounding refunds")
      {:ok, view, _html} = live(ctx.conn, ~p"/search?#{[q: "invoice rounding refunds"]}")
      render_async(view)

      assert has_element?(view, "button[phx-click=toggle_saved][aria-pressed=true]")

      view |> element("button[phx-click=toggle_saved]") |> render_click()
      assert has_element?(view, "button[phx-click=toggle_saved][aria-pressed=false]")
      assert Slipdock.SavedQueries.list(ctx.user, "search") == []
    end

    test "a saved query can be removed from the list, bringing the examples back", ctx do
      {:ok, saved} = Slipdock.SavedQueries.save(ctx.user, "search", "something of mine")

      {:ok, view, html} = live(ctx.conn, ~p"/search")
      assert html =~ "something of mine"

      view |> element(~s(button[phx-click=unsave][phx-value-id="#{saved.id}"])) |> render_click()

      html = render(view)
      refute html =~ "something of mine"
      assert html =~ "anything about flaky tests"
    end

    test "saving in one mode leaves the other mode's examples alone", ctx do
      {:ok, _} = Slipdock.SavedQueries.save(ctx.user, "ask", "a question of mine")

      {:ok, _view, html} = live(ctx.conn, ~p"/ask")
      assert html =~ "a question of mine"
      refute html =~ "What&#39;s at risk across all my boards right now?"

      {:ok, _view, html} = live(ctx.conn, ~p"/search")
      assert html =~ "anything about flaky tests"
      refute html =~ "a question of mine"
    end

    test "a saved query is clickable and runs, like an example", ctx do
      {:ok, _} = Slipdock.SavedQueries.save(ctx.user, "search", "invoice rounding refunds")
      {:ok, view, _html} = live(ctx.conn, ~p"/search")

      view |> element("button", "invoice rounding refunds") |> render_click()
      assert render_async(view) =~ "Invoice rounding is wrong on refunds"
    end

    test "nobody sees anybody else's saved queries", ctx do
      {:ok, _} = Slipdock.SavedQueries.save(ctx.user, "search", "mine alone")

      {:ok, _view, html} = live(conn_as(user_fixture("stranger@example.com")), ~p"/search")
      refute html =~ "mine alone"
      assert html =~ "anything about flaky tests"
    end

    test "an empty box has no star to press", ctx do
      {:ok, view, _html} = live(ctx.conn, ~p"/search")
      refute has_element?(view, "button[phx-click=toggle_saved]")
    end
  end

  test "an example is clickable, and searches rather than just reading as a hint", ctx do
    {:ok, view, _html} = live(ctx.conn, ~p"/search")

    view |> element("button", "anything about flaky tests") |> render_click()
    html = render_async(view)

    # It ran as a search, not as a question: results, no "Searched …" chips.
    assert html =~ "cards"
    refute html =~ "it looked at"
  end

  test "archived cards need asking for", ctx do
    {:ok, _} = Boards.archive_card(ctx.refunds)
    {:ok, _} = Search.index_card(ctx.refunds.id)

    {:ok, view, _html} = live(ctx.conn, ~p"/search")
    view |> form("#deep-search") |> render_change(%{"q" => "invoice rounding refunds"})
    refute render_async(view) =~ "Invoice rounding is wrong on refunds"

    view |> element("button", "Include archived") |> render_click()
    html = render_async(view)
    assert html =~ "Invoice rounding is wrong on refunds"
    assert html =~ "archived"
  end

  test "a board filter narrows the search", ctx do
    elsewhere = board_fixture(%{"name" => "Elsewhere"}, owner: ctx.user)
    stray = card_fixture(hd(elsewhere.columns), %{"title" => "Invoice rounding elsewhere"})
    {:ok, _} = Search.index_card(stray.id)

    {:ok, view, _html} = live(ctx.conn, ~p"/search")
    view |> form("#deep-search") |> render_change(%{"q" => "invoice rounding"})
    html = render_async(view)
    assert html =~ "Invoice rounding is wrong on refunds"

    view |> element("select[name=board]") |> render_change(%{"board" => to_string(elsewhere.id)})
    html = render_async(view)
    assert html =~ "Invoice rounding elsewhere"
    refute html =~ "Invoice rounding is wrong on refunds"
  end

  test "someone else's boards are not searchable", ctx do
    stranger = user_fixture("stranger@example.com")
    {:ok, view, _html} = live(conn_as(stranger), ~p"/search")

    view |> form("#deep-search") |> render_change(%{"q" => "invoice rounding refunds"})
    html = render_async(view)
    refute html =~ "Invoice rounding is wrong on refunds"
    assert html =~ "Nothing close enough"

    # Given read access, the same query finds it.
    {:ok, _} = Access.grant(ctx.board, stranger, "read", ctx.user)
    {:ok, view, _html} = live(conn_as(stranger), ~p"/search")
    view |> form("#deep-search") |> render_change(%{"q" => "invoice rounding refunds"})
    assert render_async(view) =~ "Invoice rounding is wrong on refunds"
  end

  test "a result links to the card it is about", ctx do
    {:ok, view, _html} = live(ctx.conn, ~p"/search")
    view |> form("#deep-search") |> render_change(%{"q" => "invoice rounding refunds"})
    render_async(view)

    assert view
           |> element("#result-card-#{ctx.refunds.id} a")
           |> render() =~ "/boards/#{ctx.board.id}/cards/#{ctx.refunds.id}"
  end
end
