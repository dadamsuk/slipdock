defmodule SlipdockWeb.BoardSharedLiveTest do
  @moduledoc """
  The receiving end of a share: the Shared page a board somebody else owns
  gets on your board menu, and the Discard button on it.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Access, Accounts}

  setup %{user: user} do
    owner = user_fixture("owner@example.com")
    board = board_fixture(%{"name" => "Theirs"}, owner: owner)
    {:ok, _} = Access.grant(board, user, "read", owner)
    %{owner: owner, board: board}
  end

  test "the board menu offers Shared for somebody else's board", %{conn: conn, board: board} do
    {:ok, _view, html} = live(conn, ~p"/")
    assert html =~ ~p"/boards/#{board}/shared"
    assert html =~ "Shared"
  end

  test "a board of your own has no Shared item", %{conn: conn, user: user} do
    mine = board_fixture(%{"name" => "Mine"}, owner: user)
    {:ok, _view, html} = live(conn, ~p"/")
    refute html =~ ~p"/boards/#{mine}/shared"
  end

  test "the page says who shared it and on what terms", %{conn: conn, board: board} do
    {:ok, _view, html} = live(conn, ~p"/boards/#{board}/shared")
    assert html =~ "Shared with you"
    assert html =~ "Theirs"
    assert html =~ "owner@example.com"
    assert html =~ "The whole board"
    assert html =~ "read only"
  end

  test "discarding takes the board off your list", %{conn: conn, user: user, board: board} do
    {:ok, view, _html} = live(conn, ~p"/boards/#{board}/shared")

    assert {:error, {:live_redirect, %{to: "/"}}} =
             view |> element("button[phx-click=discard]") |> render_click()

    assert Access.board_permission(user, board) == :none
    assert Access.list_boards(user) == []
    # The board itself is untouched.
    assert Slipdock.Boards.get_board!(board.id).name == "Theirs"

    # And it is no longer reachable, so neither is its Shared page.
    assert {:error, {:live_redirect, %{to: "/"}}} = live(conn, ~p"/boards/#{board}/shared")
  end

  test "a group's grant is not yours to discard", %{conn: conn, user: user, owner: owner} do
    board = board_fixture(%{"name" => "Crew board"}, owner: owner)
    {:ok, group} = Accounts.create_group(owner, %{"name" => "Crew"})
    {:ok, _} = Accounts.add_group_member(group, user.email)
    {:ok, _} = Access.grant(board, group, "read", owner)

    {:ok, view, html} = live(conn, ~p"/boards/#{board}/shared")
    assert html =~ "through the group"
    assert html =~ "Crew"
    assert has_element?(view, "button[phx-click=discard][disabled]")

    # Nothing of theirs to take away, so the access stands.
    assert {:ok, :read} = Access.discard_board(user, board)
    assert Access.board_permission(user, board) == :read
  end

  test "a view grant is listed, and discarding it closes the window", %{
    conn: conn,
    user: user,
    owner: owner
  } do
    board = board_fixture(%{"name" => "Viewed"}, owner: owner)
    {:ok, view_rec} = Slipdock.Boards.create_saved_view(board, %{"name" => "Due soon"})
    {:ok, _} = Access.grant(view_rec, user, "read", owner)
    assert Access.board_permission(user, board) == :view

    {:ok, lv, html} = live(conn, ~p"/boards/#{board}/shared")
    assert html =~ "Due soon"

    assert {:error, {:live_redirect, %{to: "/"}}} =
             lv |> element("button[phx-click=discard]") |> render_click()

    assert Access.board_permission(user, board) == :none
  end

  test "the owner is sent to the board's settings instead", %{board: board, owner: owner} do
    assert {:error, {:live_redirect, %{to: to}}} =
             live(conn_as(owner), ~p"/boards/#{board}/shared")

    assert to == ~p"/boards/#{board}/settings"
    assert {:error, :owner} = Access.discard_board(owner, board)
  end

  test "a stranger is turned away", %{board: board} do
    stranger = user_fixture("stranger@example.com")

    assert {:error, {:live_redirect, %{to: "/"}}} =
             live(conn_as(stranger), ~p"/boards/#{board}/shared")
  end
end
