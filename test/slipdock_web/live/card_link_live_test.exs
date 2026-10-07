defmodule SlipdockWeb.CardLinkLiveTest do
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.Boards

  # The open card shows its id at the top, as a link to the card's full
  # address that the CopyLink hook copies instead of following.

  setup do
    board = board_fixture(%{"name" => "Plan"})
    card = card_fixture(hd(board.columns), %{"title" => "Call the printers"})
    %{board: board, card: card}
  end

  defp card_url(card),
    do: SlipdockWeb.Endpoint.url() <> "/boards/#{card.board_id}/cards/#{card.id}"

  test "the open card shows its id, linking to its full address", %{
    conn: conn,
    board: board,
    card: card
  } do
    {:ok, view, _} = live(conn, ~p"/boards/#{board}/cards/#{card.id}")

    link = element(view, "#card-modal a#card-copy-link[phx-hook=CopyLink]")
    assert render(link) =~ "##{card.id}"
    assert has_element?(view, ~s(#card-copy-link[href="#{card_url(card)}"]))
    # Absolute, so what lands on the clipboard works when pasted elsewhere.
    assert card_url(card) =~ ~r{^https?://}
  end

  test "a subcard links to itself on its sub-board, not to its parent", %{
    conn: conn,
    card: epic
  } do
    {:ok, t} = Boards.find_template("Simple")
    {:ok, sub} = sub_board(epic, t)
    sub = Boards.get_board!(sub.id)
    child = card_fixture(hd(sub.columns), %{"title" => "Proofs"})

    {:ok, view, _} = live(conn, ~p"/boards/#{sub}/cards/#{child.id}")

    assert has_element?(view, ~s(#card-copy-link[href="#{card_url(child)}"]), "##{child.id}")
    refute has_element?(view, "#card-copy-link", "##{epic.id}")
  end

  test "a read-only reader can still copy the link", %{board: board, card: card} do
    reader = user_fixture("reader@example.com")
    share_fixture(board, reader, "read")

    {:ok, view, _} = live(conn_as(reader), ~p"/boards/#{board}/cards/#{card.id}")

    # The panel's fieldset is disabled for them, which would disable a
    # button inside it; the copy control is a link, which it does not.
    assert has_element?(view, "#card-modal fieldset[disabled]")
    assert has_element?(view, ~s(a#card-copy-link[href="#{card_url(card)}"]))
    refute has_element?(view, "button#card-copy-link")
  end
end
