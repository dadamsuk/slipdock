defmodule SlipdockWeb.PulseLiveTest do
  @moduledoc """
  The board's pulse strip (#1113): absent until the owner ticks "Show the
  board's pulse" in settings, then a line of plain words over the lists.
  Nobody else can turn it on.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.Boards

  setup %{user: user} do
    board = board_fixture(%{"name" => "Strip"}, owner: user)
    [_backlog, _todo, doing, _done] = board.columns
    card_fixture(doing, %{"title" => "Underway"})
    card_fixture(doing, %{"title" => "Stuck", "flags" => ["waiting"]})
    %{board: board}
  end

  test "absent by default, there once the owner ticks the setting", %{conn: conn, board: board} do
    {:ok, view, _} = live(conn, ~p"/boards/#{board}")
    refute has_element?(view, "#board-pulse")

    {:ok, settings, _} = live(conn, ~p"/boards/#{board}/settings")
    refute has_element?(settings, "#board-show-pulse[checked]")
    settings |> form("#board-form", board: %{"show_pulse" => "true"}) |> render_submit()
    assert Boards.get_board!(board.id).show_pulse

    {:ok, view, _} = live(conn, ~p"/boards/#{board}")
    assert has_element?(view, "#board-pulse", "2 in progress · 1 waiting · 0 done this week")

    {:ok, settings, _} = live(conn, ~p"/boards/#{board}/settings")
    assert has_element?(settings, "#board-show-pulse[checked]")
    settings |> form("#board-form", board: %{"show_pulse" => "false"}) |> render_submit()

    {:ok, view, _} = live(conn, ~p"/boards/#{board}")
    refute has_element?(view, "#board-pulse")
  end

  test "someone the board is shared with can't turn it on", %{board: board} do
    editor = user_fixture("editor#{System.unique_integer([:positive])}@example.com")
    share_fixture(board, [editor], "write")
    conn = log_in_user(build_conn(), editor)

    {:ok, view, _} = live(conn, ~p"/boards/#{board}/settings")
    refute has_element?(view, "#board-form")
    refute has_element?(view, "#board-show-pulse")

    # Nor through the API, which is where a token of theirs would try.
    {token, _} = Slipdock.Accounts.create_api_token(editor, "theirs")

    assert build_conn()
           |> put_req_header("accept", "application/json")
           |> put_req_header("authorization", "Bearer " <> token)
           |> patch(~p"/api/boards/#{board.code}", %{"show_pulse" => true})
           |> json_response(403)

    refute Boards.get_board!(board.id).show_pulse
    {:ok, view, _} = live(conn, ~p"/boards/#{board}")
    refute has_element?(view, "#board-pulse")
  end
end
