defmodule SlipdockWeb.AssignCardLiveTest do
  use SlipdockWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures
  alias Slipdock.Boards

  setup do
    board = board_fixture()
    [col | _] = board.columns
    card = card_fixture(col, %{"title" => "Needs an owner"})
    %{board: reload(board), card: card, ada: user_fixture("ada@example.com")}
  end

  test "assigning and unassigning from the card modal saves", %{
    conn: conn,
    board: board,
    card: card,
    ada: ada
  } do
    {:ok, view, _} = live(conn, ~p"/boards/#{board}/cards/#{card.id}")

    view |> form("#card-meta-form", card: %{assignee_id: ada.id}) |> render_change()
    assert Boards.get_card!(card.id).assignee_id == ada.id
    assert has_element?(view, "#card-assignee option[selected][value='#{ada.id}']")

    view |> form("#card-meta-form", card: %{assignee_id: ""}) |> render_change()
    assert is_nil(Boards.get_card!(card.id).assignee_id)
  end
end
