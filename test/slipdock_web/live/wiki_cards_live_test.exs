defmodule SlipdockWeb.WikiCardsLiveTest do
  @moduledoc """
  A card and the documents about it, in the browser: writing one up, keeping
  it when the stub text goes, attaching one already written, and getting back
  to the card from the page.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.Wiki

  setup %{user: user} do
    board = board_fixture(%{"name" => "Handbook", "code" => "handbook"}, owner: user)
    card = card_fixture(hd(board.columns), %{"title" => "Ship the billing rewrite"})
    %{board: board, card: card}
  end

  test "“Write it up” starts a page and lands in its editor", %{
    conn: conn,
    board: board,
    card: card
  } do
    {:ok, view, _html} = live(conn, ~p"/boards/#{board}/cards/#{card}")

    assert {:error, {:live_redirect, %{to: path}}} =
             view |> element("button[phx-click='write_up']") |> render_click()

    assert {:ok, page} = Wiki.find_page(board, "ship-the-billing-rewrite")
    assert path == "/boards/#{board.id}/wiki/#{page.slug}/edit"
    assert [%{pinned: true}] = Wiki.pages_for_card(card)
  end

  test "replacing the stub text keeps the page on the card", %{
    conn: conn,
    board: board,
    card: card,
    user: user
  } do
    {:ok, page} = Wiki.create_page_from_card(card, user: user)

    {:ok, view, _html} = live(conn, ~p"/boards/#{board}/wiki/#{page.slug}/edit")

    assert {:error, {:live_redirect, _}} =
             view
             |> form("#page-form", page: %{body: "Some completely different text."})
             |> render_submit()

    assert [%{pinned: true}] = Wiki.pages_for_card(card)

    # And the card still lists it.
    {:ok, card_view, html} = live(conn, ~p"/boards/#{board}/cards/#{card}")
    assert html =~ page.title
    assert has_element?(card_view, "a[href='/boards/#{board.id}/wiki/#{page.slug}']")
  end

  test "a page already written can be attached from the card", %{
    conn: conn,
    board: board,
    card: card
  } do
    page = page_fixture(board, %{"title" => "Billing rewrite spec"})

    {:ok, view, _html} = live(conn, ~p"/boards/#{board}/cards/#{card}")

    view |> form("#card-doc-search") |> render_change(%{"q" => "billing"})
    assert has_element?(view, "button[phx-click='attach_doc'][phx-value-page='#{page.id}']")

    view
    |> element("button[phx-click='attach_doc'][phx-value-page='#{page.id}']")
    |> render_click()

    assert [%{pinned: true, page: %{id: id}}] = Wiki.pages_for_card(card)
    assert id == page.id
  end

  test "the page lists the cards it is about, and links back to them", %{
    conn: conn,
    board: board,
    card: card
  } do
    {:ok, page} = Wiki.create_page_from_card(card)

    {:ok, view, html} = live(conn, ~p"/boards/#{board}/wiki/#{page.slug}")

    assert html =~ "Cards this is about"
    assert has_element?(view, "a[href='/boards/#{board.id}/cards/#{card.id}']")
  end

  test "a card can be attached and detached from the page", %{
    conn: conn,
    board: board,
    card: card
  } do
    page = page_fixture(board, %{"title" => "Billing rewrite spec", "body" => "No references."})

    {:ok, view, _html} = live(conn, ~p"/boards/#{board}/wiki/#{page.slug}")

    view |> form("#page-card-search") |> render_change(%{"q" => "billing"})

    view
    |> element("button[phx-click='attach_card'][phx-value-id='#{card.id}']")
    |> render_click()

    assert [%{pinned: true}] = Wiki.pages_for_card(card)

    view
    |> element("button[phx-click='detach_card'][phx-value-id='#{card.id}']")
    |> render_click()

    assert [] = Wiki.pages_for_card(card)
  end
end
