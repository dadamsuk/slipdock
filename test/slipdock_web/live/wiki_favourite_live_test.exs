defmodule SlipdockWeb.WikiFavouriteLiveTest do
  @moduledoc "Favouriting a wiki page from the page itself (#1165)."
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Access, Favourites}

  setup %{user: user} do
    board = board_fixture(%{"name" => "Handbook", "code" => "wfav"}, owner: user)
    page = page_fixture(board, %{"title" => "Retry policy", "body" => "Three times."})
    %{board: board, page: page}
  end

  defp heart(page),
    do: "button[phx-click=toggle_favourite][phx-value-kind=page][phx-value-id='#{page.id}']"

  test "the heart adds the page to favourites and takes it off again", %{
    conn: conn,
    board: board,
    page: page,
    user: user
  } do
    {:ok, view, _} = live(conn, ~p"/boards/#{board}/wiki/#{page.slug}")
    assert has_element?(view, heart(page) <> "[aria-pressed=false]")

    view |> element(heart(page)) |> render_click()
    assert Favourites.favourite?(Favourites.marks(user), :page, page.id)
    assert has_element?(view, heart(page) <> "[aria-pressed=true]")

    # It shows on /favourites, linked back to the page.
    {:ok, fav, _} = live(conn, ~p"/favourites")
    assert has_element?(fav, "#favourites-page a[href='/boards/#{board.id}/wiki/#{page.slug}']")

    view |> element(heart(page)) |> render_click()
    refute Favourites.favourite?(Favourites.marks(user), :page, page.id)
    assert has_element?(view, heart(page) <> "[aria-pressed=false]")
  end

  test "a reader who can't edit the page may still favourite it", %{
    conn: conn,
    board: board,
    page: page,
    user: user
  } do
    reader = user_fixture("reader@example.com")
    {:ok, _} = Access.grant(board, reader, "read", user)

    {:ok, view, _} = live(log_in_user(conn, reader), ~p"/boards/#{board}/wiki/#{page.slug}")
    view |> element(heart(page)) |> render_click()

    assert Favourites.favourite?(Favourites.marks(reader), :page, page.id)
    # Only theirs: the owner's favourites are untouched.
    refute Favourites.favourite?(Favourites.marks(user), :page, page.id)
  end

  test "a forged toggle for a page the reader can't see, or a bad kind, changes nothing", %{
    conn: conn,
    board: board,
    page: page,
    user: user
  } do
    stranger = user_fixture("stranger@example.com")
    hidden_board = board_fixture(%{"name" => "Private", "code" => "wfavp"}, owner: stranger)
    hidden = page_fixture(hidden_board, %{"title" => "Secret", "body" => "x"})

    {:ok, view, _} = live(conn, ~p"/boards/#{board}/wiki/#{page.slug}")

    render_click(view, "toggle_favourite", %{"kind" => "page", "id" => "#{hidden.id}"})
    render_click(view, "toggle_favourite", %{"kind" => "nonsense", "id" => "#{page.id}"})
    render_click(view, "toggle_favourite", %{"kind" => "page", "id" => "abc"})

    assert Favourites.count(user) == 0
    assert has_element?(view, heart(page) <> "[aria-pressed=false]")
  end
end
