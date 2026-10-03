defmodule SlipdockWeb.NarrativeLiveTest do
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures
  alias Slipdock.Boards

  setup do
    board = board_fixture(%{"name" => "Story"})
    [backlog, _, _, done] = board.columns
    card = card_fixture(backlog, %{"title" => "Shipped thing"})
    :ok = Boards.move_card(card.id, done.id)
    quiet = card_fixture(backlog, %{"title" => "Quiet thing"})
    %{board: reload(board), card: card, quiet: quiet, done: done}
  end

  test "a placed wiki page's story opens the page, not a card", %{conn: conn, board: board} do
    [backlog | _] = board.columns
    page = page_fixture(board, %{"title" => "The spec"})
    {:ok, page} = Slipdock.Wiki.place(page, backlog)

    {:ok, view, html} = live(conn, ~p"/boards/#{board}/narrative")
    assert html =~ "The spec"

    view |> element("#story-page-#{page.id} h3", "The spec") |> render_click()
    assert has_element?(view, "#page-panel")
  end

  test "the narrative tab tells the story and can be grouped and ranged", %{
    conn: conn,
    board: board
  } do
    {:ok, view, html} = live(conn, ~p"/boards/#{board}/narrative")
    assert html =~ "What happened"
    assert html =~ "moved “Shipped thing” to Done"
    assert html =~ "completed “Shipped thing”"

    html = view |> form("#swim-config", %{"rows" => "column", "span" => "7"}) |> render_change()
    assert html =~ "Done"
    assert html =~ "1 of 1 changed"
    assert_patch(view)

    html =
      view
      |> form("#swim-config", %{"from" => "2020-01-01", "to" => "2020-01-02"})
      |> render_change()

    assert html =~ "0 of 2"
    assert html =~ "Unchanged:"
  end

  test "the Display menu chooses what is told and can add a card summary", %{
    conn: conn,
    board: board,
    card: card
  } do
    {:ok, _} = Boards.update_card(card, %{"priority" => "high", "due_date" => "2031-03-01"})
    {:ok, _} = Boards.add_comment(card, "Shipped it, hooray")
    {:ok, view, html} = live(conn, ~p"/boards/#{board}/narrative")
    assert has_element?(view, "#display-tell input[name='tell[]'][value=comment_text][checked]")
    refute has_element?(view, "#display-tell input[name='tell[]'][value=summary][checked]")
    assert html =~ "Shipped it, hooray"
    assert html =~ "moved “Shipped thing” to Done"
    refute has_element?(view, "#story-#{card.id} dl")

    # Comments without their text, no moves, plus the summary.
    html =
      view
      |> form("#swim-config", %{"tell" => ["", "created", "completed", "comments", "summary"]})
      |> render_change()

    assert_patch(view)
    assert html =~ "commented on “Shipped thing”"
    refute html =~ "Shipped it, hooray"
    refute html =~ "moved “Shipped thing”"
    assert html =~ "completed “Shipped thing”"
    assert has_element?(view, "#story-#{card.id} dl dt", "Priority")
    assert has_element?(view, "#story-#{card.id} dl dt", "Due")
    assert has_element?(view, "#story-#{card.id} dl dd", "Done")

    # Nothing but the summary section: every card reads as unchanged.
    html =
      view |> form("#swim-config", %{"tell" => ["", "summary", "unchanged"]}) |> render_change()

    assert html =~ "0 of 2"
    assert html =~ "Unchanged:"

    # Unchanged cards can be hidden too.
    html = view |> form("#swim-config", %{"tell" => ["", "summary"]}) |> render_change()
    refute html =~ "Unchanged:"
  end

  test "a saved narrative view stays relative to today and can be published", %{
    conn: conn,
    board: board
  } do
    {:ok, view, _} =
      live(
        conn,
        ~p"/boards/#{board}/narrative?span=30&from=2020-01-01&to=2020-01-02&q=shipped&tell=created,summary"
      )

    view |> form("#swim-save-view-0", %{"name" => "Fortnightly"}) |> render_submit()

    [saved] = Boards.list_saved_views(board.id)
    assert saved.config["mode"] == "narrative"
    assert saved.config["span"] == "30"
    assert saved.config["q"] == "shipped"
    assert saved.config["tell"] == ["created", "summary"]
    refute Map.has_key?(saved.config, "from")

    {:ok, saved} = Boards.publish_saved_view(saved)
    {:ok, _lv, html} = live(Phoenix.ConnTest.build_conn(), ~p"/p/#{saved.public_token}")
    assert html =~ "What happened"
    assert html =~ "Shipped thing"
    refute html =~ "Quiet thing"
    assert html =~ "1 of 1"
    # The published page tells what the saved view chose: no moves, with a summary.
    refute html =~ "moved “Shipped thing”"
    assert html =~ "added “Shipped thing”"
    assert html =~ "Progress" or html =~ "List"
  end
end
