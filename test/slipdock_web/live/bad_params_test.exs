defmodule SlipdockWeb.BadParamsTest do
  @moduledoc """
  Events carry whatever the client sent — a stale page, a hand-made frame. An
  id that isn't one, or names nothing, must leave the page standing rather
  than crash the socket.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  setup do
    board = board_fixture(%{"name" => "Sturdy"})
    card = card_fixture(hd(board.columns), %{"title" => "Still here"})
    %{board: board, card: card}
  end

  test "the board shrugs off ids that aren't ids", %{conn: conn, board: board} do
    {:ok, view, _} = live(conn, ~p"/boards/#{board}")

    for {event, params} <- [
          {"filter_tag", %{"id" => "x"}},
          {"start_rename_column", %{"id" => "x"}},
          {"move_column", %{"id" => "x"}},
          {"start_add_card", %{"id" => "x"}},
          {"open_move_board", %{"id" => "999999999"}},
          {"open_sprint_picker", %{"id" => "nope"}},
          {"toggle_favourite", %{"kind" => "board", "id" => "nope"}}
        ] do
      render_click(view, event, params)
      assert render(view) =~ "Still here"
    end
  end

  test "a vote that isn't a number changes nothing", %{conn: conn, board: board, card: card} do
    {:ok, view, _} = live(conn, ~p"/boards/#{board}/cards/#{card.id}")
    render_click(view, "vote", %{"count" => "lots"})
    assert render(view) =~ "Still here"
  end

  test "SlipdockWeb.Params reads ids and refuses the rest" do
    alias SlipdockWeb.Params
    assert Params.id("12") == 12
    assert Params.id(" 7 ") == 7
    assert Params.id(3) == 3
    assert Params.id("0") == nil
    assert Params.id("-4") == nil
    assert Params.id("12abc") == nil
    assert Params.id(%{}) == nil
    assert Params.int("-2") == -2
    assert Params.int("two") == nil
  end
end
