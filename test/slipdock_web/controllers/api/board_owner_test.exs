defmodule SlipdockWeb.API.BoardOwnerTest do
  @moduledoc """
  Every board response names its owner, and a listing says which of them
  belong to somebody else — what a client needs in order to show whose board
  it is looking at.
  """
  use SlipdockWeb.ConnCase, async: false

  import Slipdock.Fixtures

  alias Slipdock.{Access, Accounts}

  setup %{conn: conn} do
    %{conn: put_req_header(conn, "accept", "application/json")}
  end

  test "your own board names you, and is not shared", %{conn: conn, user: user} do
    board = board_fixture(%{"name" => "Mine"}, owner: user)

    assert %{"boards" => boards} = conn |> get(~p"/api/boards") |> json_response(200)
    assert [listed] = Enum.filter(boards, &(&1["id"] == board.id))
    assert listed["owner"]["email"] == user.email
    assert listed["shared"] == false

    assert %{"board" => shown} = conn |> get(~p"/api/boards/#{board.id}") |> json_response(200)
    assert shown["owner"]["email"] == user.email
  end

  test "a board granted to you names its owner and is marked shared", %{conn: conn, user: user} do
    other = user_fixture("nadia@example.com")
    {:ok, other} = Accounts.update_profile(other, %{"name" => "Nadia"})
    board = board_fixture(%{"name" => "Theirs"}, owner: other)
    {:ok, _} = Access.grant(board, user, "read", other)

    assert %{"boards" => boards} = conn |> get(~p"/api/boards") |> json_response(200)
    assert [listed] = Enum.filter(boards, &(&1["id"] == board.id))
    assert listed["owner"]["name"] == "Nadia"
    assert listed["owner"]["email"] == "nadia@example.com"
    assert listed["shared"] == true

    assert %{"board" => shown} = conn |> get(~p"/api/boards/#{board.id}") |> json_response(200)
    assert shown["owner"]["name"] == "Nadia"
  end

  test "the agent guide says who a shared board belongs to", %{conn: conn, user: user} do
    other = user_fixture("nadia@example.com")
    {:ok, other} = Accounts.update_profile(other, %{"name" => "Nadia"})
    board = board_fixture(%{"name" => "Theirs"}, owner: other)
    {:ok, _} = Access.grant(board, user, "read", other)

    guide = conn |> get(~p"/api/guide") |> response(200)

    assert guide =~ "owned by Nadia and shared with you"
    refute guide =~ "owned by somebody else"
    assert board.id
  end
end
