defmodule SlipdockWeb.MoveBoardLiveTest do
  use SlipdockWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Access, Boards}

  setup do
    from = board_fixture(%{"name" => "Plan"})
    to = board_fixture(%{"name" => "Errands"})
    [_backlog, todo | _] = from.columns
    card = card_fixture(todo, %{"title" => "Call the printers"})
    %{from: from, to: to, todo: todo, card: card}
  end

  # The card's list menu on the board; the open card has its own (#card-move-board).
  defp open_picker(view, card),
    do:
      view
      |> element("#move-menu-#{card.id} button[phx-click=open_move_board]")
      |> render_click()

  test "the card's own menu leads to the picker, and the picker moves it", %{
    conn: conn,
    from: from,
    to: to,
    card: card
  } do
    {:ok, view, _} = live(conn, ~p"/boards/#{from}")

    # The list menu on the card offers another board.
    assert has_element?(view, "#move-menu-#{card.id} button[phx-click=open_move_board]")

    open_picker(view, card)
    assert has_element?(view, "#move-board-modal")
    assert render(view) =~ "Errands"
    # The board it is already on is not somewhere to move it to.
    refute has_element?(view, "button[phx-click=move_board_pick][phx-value-id='#{from.id}']")

    view
    |> element("button[phx-click=move_board_pick][phx-value-id='#{to.id}']")
    |> render_click()

    backlog = hd(to.columns)

    html =
      view
      |> element("button[phx-click=move_card_board][phx-value-column='#{backlog.id}']")
      |> render_click()

    assert html =~ "Moved “Call the printers” to Errands › Backlog."
    moved = Boards.get_card!(card.id)
    assert moved.board_id == to.id and moved.column_id == backlog.id

    # It is gone from the board it left.
    refute has_element?(view, "#card-#{card.id}")
  end

  test "the flash says what did not survive the crossing", %{
    conn: conn,
    from: from,
    to: to,
    card: card
  } do
    bug = tag_fixture(from, "bug")
    Boards.set_card_tags(card, [bug])

    {:ok, view, _} = live(conn, ~p"/boards/#{from}")
    open_picker(view, card)

    view
    |> element("button[phx-click=move_board_pick][phx-value-id='#{to.id}']")
    |> render_click()

    html =
      view
      |> element("button[phx-click=move_card_board][phx-value-column='#{hd(to.columns).id}']")
      |> render_click()

    assert html =~ "1 tag added to Errands"
  end

  test "picking a board can be undone without leaving the picker", %{
    conn: conn,
    from: from,
    to: to,
    card: card
  } do
    {:ok, view, _} = live(conn, ~p"/boards/#{from}")
    open_picker(view, card)

    view
    |> element("button[phx-click=move_board_pick][phx-value-id='#{to.id}']")
    |> render_click()

    assert has_element?(view, "button[phx-click=move_card_board]")

    view |> element("button[phx-click=move_board_pick][phx-value-id='']") |> render_click()
    refute has_element?(view, "button[phx-click=move_card_board]")
    assert has_element?(view, "button[phx-click=move_board_pick][phx-value-id='#{to.id}']")
  end

  test "from an open card, the picker stands in for it and the card is followed", %{
    conn: conn,
    from: from,
    to: to,
    card: card
  } do
    {:ok, view, _} = live(conn, ~p"/boards/#{from}/cards/#{card.id}")
    assert has_element?(view, "#card-modal")

    view |> element("#card-move-board") |> render_click()
    refute has_element?(view, "#card-modal")
    assert has_element?(view, "#move-board-modal")

    view
    |> element("button[phx-click=move_board_pick][phx-value-id='#{to.id}']")
    |> render_click()

    view
    |> element("button[phx-click=move_card_board][phx-value-column='#{hd(to.columns).id}']")
    |> render_click()

    assert_redirect(view, ~p"/boards/#{to.id}/cards/#{card.id}")
  end

  test "closing the picker brings the card back", %{conn: conn, from: from, card: card} do
    {:ok, view, _} = live(conn, ~p"/boards/#{from}/cards/#{card.id}")

    view |> element("#card-move-board") |> render_click()
    refute has_element?(view, "#card-modal")

    view |> element("#move-board-modal button[aria-label=Close]") |> render_click()
    assert has_element?(view, "#card-modal")
  end

  test "read-only access to the card refuses the move", %{conn: conn, card: card, user: user} do
    reader = user_fixture("reader@example.com")
    theirs = board_fixture(%{"name" => "Theirs"}, owner: reader)
    [column | _] = theirs.columns
    other_card = card_fixture(column, %{"title" => "Not yours"})
    {:ok, _} = Access.grant(theirs, user, "read", reader)

    {:ok, view, _} = live(conn, ~p"/boards/#{theirs}")

    # There is no menu to open, and asking directly is refused.
    refute has_element?(view, "button[phx-click=open_move_board]")

    html = render_click(view, "open_move_board", %{"id" => to_string(other_card.id)})
    assert html =~ "read-only access to that card"
    refute has_element?(view, "#move-board-modal")
    assert Boards.get_card!(other_card.id).board_id == theirs.id
    assert card.board_id
  end

  test "only boards you can write to are offered", %{conn: conn, from: from, card: card} do
    other = user_fixture("elsewhere@example.com")
    theirs = board_fixture(%{"name" => "Theirs"}, owner: other)

    {:ok, view, _} = live(conn, ~p"/boards/#{from}")
    open_picker(view, card)

    refute has_element?(view, "button[phx-click=move_board_pick][phx-value-id='#{theirs.id}']")
  end
end
