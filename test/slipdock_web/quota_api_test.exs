defmodule SlipdockWeb.QuotaAPITest do
  @moduledoc """
  What an agent is told when a board is full.

  The point of the status code and the name: a 422 "validation failed" reads
  like something wrong with the request, so an agent fixes the title and tries
  again, forever.
  """
  use SlipdockWeb.ConnCase, async: false

  import Slipdock.Fixtures

  alias Slipdock.{Accounts, Boards, Settings}

  setup %{conn: conn, user: user} do
    {:ok, _} =
      Settings.complete_setup(%{"admin_email" => "admin@example.com", "free_card_limit" => 1})

    board = board_fixture(%{"name" => "Full"}, owner: user)
    {:ok, _} = Boards.create_card(hd(board.columns), %{"title" => "The only one"})

    %{conn: conn, board: board}
  end

  test "creating a card past the limit is refused, by name", %{conn: conn, board: board} do
    conn =
      post(conn, ~p"/api/boards/#{board.id}/cards", %{
        "title" => "One too many",
        "column" => "To Do"
      })

    body = json_response(conn, 402)

    assert body["error"] == "card_limit_reached"
    assert body["retryable"] == false
    assert body["message"] =~ "archive"
  end

  test "an ordinary validation failure still looks like one", %{conn: conn, board: board} do
    {:ok, _} = Settings.update(%{"free_card_limit" => 100})

    conn = post(conn, ~p"/api/boards/#{board.id}/cards", %{"column" => "To Do"})

    assert json_response(conn, 422)["error"] == "validation failed"
  end

  test "an admin is not stopped", %{conn: conn, board: board, user: user} do
    {:ok, _} = Accounts.promote(user)

    conn =
      post(conn, ~p"/api/boards/#{board.id}/cards", %{"title" => "Fine", "column" => "To Do"})

    assert json_response(conn, 201)
  end
end
