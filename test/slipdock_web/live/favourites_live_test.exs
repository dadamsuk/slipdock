defmodule SlipdockWeb.FavouritesLiveTest do
  use SlipdockWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Boards, Favourites}

  setup do
    board = board_fixture(%{"name" => "Plan"})
    [_backlog, todo | _] = board.columns
    card = card_fixture(todo, %{"title" => "Write the post"})
    %{board: board, todo: todo, card: card}
  end

  defp heart(kind, id),
    do: "button[phx-click=toggle_favourite][phx-value-kind=#{kind}][phx-value-id='#{id}']"

  test "the phone's fifth tab is Favourites, and Templates keeps the avatar menu", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/")

    assert html =~ ~s(href="/favourites")
    assert html =~ "Favourites"
    # The bottom bar no longer offers Templates; the avatar menu still does.
    refute html =~ ~s(<span phx-r="" class="text-[0.625rem] font-medium leading-none">Templates)
    assert html =~ ~s(href="/templates")
  end

  test "the desktop header carries the heart, and marks it on the page itself", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/")
    # Hidden below 640px: down there the bottom bar's fifth tab is the heart.
    assert has_element?(
             view,
             "#favourites-link[href='/favourites'][class*='hidden sm:inline-flex']"
           )

    refute has_element?(view, "#favourites-link[aria-current=page]")

    {:ok, own, _} = live(conn, ~p"/favourites")
    assert has_element?(own, "#favourites-link[aria-current=page]")
  end

  test "an empty list says what to press", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/favourites")
    assert html =~ "Nothing favourited yet"
  end

  test "a list favourited on the board shows up, and links back to it", %{
    conn: conn,
    board: board,
    todo: todo
  } do
    {:ok, view, _} = live(conn, ~p"/boards/#{board}")
    assert has_element?(view, "#{heart("column", todo.id)}[aria-pressed=false]")

    view |> element(heart("column", todo.id)) |> render_click()
    assert has_element?(view, "#{heart("column", todo.id)}[aria-pressed=true]")

    {:ok, _favourites, html} = live(conn, ~p"/favourites")
    assert html =~ "To Do"
    assert html =~ "Plan"
    assert html =~ ~s(href="/boards/#{board.id}?list=#{todo.id}")
  end

  test "opening a board with ?list= tells the browser which list to show", %{
    conn: conn,
    board: board,
    todo: todo
  } do
    {:ok, view, _} = live(conn, ~p"/boards/#{board}?list=#{todo.id}")
    assert_push_event(view, "scroll-to-list", %{id: id})
    assert id == to_string(todo.id)

    # A list that is not on this board is simply ignored.
    {:ok, other, _} = live(conn, ~p"/boards/#{board}?list=999999")
    refute_push_event(other, "scroll-to-list", %{})
  end

  test "a card is favourited from the card itself, read-only access and all", %{
    conn: conn,
    board: board,
    card: card,
    user: user
  } do
    {:ok, view, _} = live(conn, ~p"/boards/#{board}/cards/#{card.id}")

    view |> element(heart("card", card.id)) |> render_click()
    assert Favourites.favourite?(Favourites.marks(user), :card, card.id)

    {:ok, _favourites, html} = live(conn, ~p"/favourites")
    assert html =~ "Write the post"
    assert html =~ ~s(href="/boards/#{board.id}/cards/#{card.id}")
  end

  test "the page's own heart takes something off the list", %{
    conn: conn,
    card: card,
    user: user
  } do
    {:ok, :added} = Favourites.toggle(user, :card, card.id)

    {:ok, view, _} = live(conn, ~p"/favourites")
    assert has_element?(view, "#{heart("card", card.id)}[aria-pressed=true]")

    view |> element(heart("card", card.id)) |> render_click()
    assert render(view) =~ "Nothing favourited yet"
    assert Favourites.count(user) == 0
  end

  test "each kind gets its own section", %{conn: conn, user: user, board: board, card: card} do
    todo = Enum.at(board.columns, 1)

    {:ok, view} =
      Boards.create_saved_view(board, %{"name" => "By tag", "config" => %{"rows" => "tag"}})

    for {kind, id} <- [{:board, board.id}, {:column, todo.id}, {:card, card.id}, {:view, view.id}],
        do: {:ok, :added} = Favourites.toggle(user, kind, id)

    {:ok, live_view, _} = live(conn, ~p"/favourites")

    for kind <- ~w(board column card view),
        do: assert(has_element?(live_view, "#favourites-#{kind}"))
  end

  test "a favourite is one person's own", %{conn: conn, board: board, card: card, user: user} do
    other = user_fixture("nosy@example.com")
    {:ok, _} = Slipdock.Access.grant(board, other, "read", user)
    {:ok, :added} = Favourites.toggle(other, :card, card.id)

    # They favourited it; this session did not, so this session's page is empty.
    {:ok, _view, html} = live(conn, ~p"/favourites")
    assert html =~ "Nothing favourited yet"
    assert Favourites.count(other) == 1
  end
end
