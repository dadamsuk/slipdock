defmodule SlipdockWeb.AssignCardLiveTest do
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures
  alias Slipdock.Boards
  alias Slipdock.Boards.Card

  # The card panel is a LiveComponent; what it is pushed goes to it.
  defp card_panel(view), do: with_target(view, "#board-card")

  setup do
    board = board_fixture()
    [col | _] = board.columns
    card = card_fixture(col, %{"title" => "Needs an owner"})
    ada = user_fixture("ada@example.com")
    bob = user_fixture("bob@example.com")
    share_fixture(board, [ada, bob])

    %{board: reload(board), card: card, ada: ada, bob: bob}
  end

  test "people are added to and taken off the card from its modal", %{
    conn: conn,
    board: board,
    card: card,
    ada: ada,
    bob: bob
  } do
    {:ok, view, _} = live(conn, ~p"/boards/#{board}/cards/#{card.id}")

    view |> form("#card-meta-form", card: %{add_assignee_id: ada.id}) |> render_change()
    assert Boards.get_card!(card.id).assignee_id == ada.id
    assert has_element?(view, "#card-assignee-#{ada.id}")

    view |> form("#card-meta-form", card: %{add_assignee_id: bob.id}) |> render_change()
    ids = Boards.get_card!(card.id) |> Card.assignees() |> Enum.map(& &1.id)
    assert ids == [ada.id, bob.id]
    assert has_element?(view, "#card-assignee-#{bob.id}")
    # Somebody already on the card isn't offered again.
    refute has_element?(view, "#card-assignees select option[value='#{ada.id}']")

    view |> element("#card-assignee-#{ada.id} button") |> render_click()
    card = Boards.get_card!(card.id)
    assert card.assignee_id == bob.id
    assert Enum.map(Card.assignees(card), & &1.id) == [bob.id]
    refute has_element?(view, "#card-assignee-#{ada.id}")
  end

  # The select only offers people who may be put on the card, but the id is
  # the browser's to send; a forged one is refused, and names nobody.
  test "an id from outside the board is refused", %{conn: conn, board: board, card: card} do
    stranger = user_fixture("stranger@example.com")
    {:ok, view, _} = live(conn, ~p"/boards/#{board}/cards/#{card.id}")

    render_hook(card_panel(view), "card_change", %{
      "card" => %{"add_assignee_id" => "#{stranger.id}"}
    })

    html = render(view)
    assert html =~ "can&#39;t be put on this card"
    refute html =~ "stranger@example.com"
    assert Boards.get_card!(card.id).assignees == []

    render_hook(card_panel(view), "card_change", %{"card" => %{"assignee_id" => "99999999"}})
    assert Boards.get_card!(card.id).assignees == []
  end
end
