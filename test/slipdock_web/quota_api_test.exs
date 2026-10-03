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

  test "an admin is not stopped by the free tier's allowance", %{
    conn: conn,
    board: board,
    user: user
  } do
    {:ok, _} = Accounts.promote(user)

    conn =
      post(conn, ~p"/api/boards/#{board.id}/cards", %{"title" => "Fine", "column" => "To Do"})

    assert json_response(conn, 201)
  end

  test "a wiki page is refused by the same limit, since it is an item too", %{
    conn: conn,
    board: board
  } do
    conn = post(conn, ~p"/api/boards/#{board.id}/pages", %{"title" => "No room"})

    assert json_response(conn, 402)["error"] == "card_limit_reached"
  end

  test "a board past the board ceiling is refused by its own name", %{conn: conn} do
    {:ok, _} = Settings.update(%{"free_card_limit" => nil, "board_limit" => 1})

    conn = post(conn, ~p"/api/boards", %{"name" => "One too many"})

    body = json_response(conn, 402)
    assert body["error"] == "board_limit_reached"
    assert body["retryable"] == false
  end

  test "an expired trial is its own refusal, not a card limit", %{conn: conn, board: board} do
    {:ok, _} =
      Settings.update(%{"free_card_limit" => nil, "trial_days" => 1, "trial_enabled" => true})

    Slipdock.Repo.get!(Slipdock.Accounts.User, board.owner_id)
    |> Ecto.Changeset.change(
      inserted_at: DateTime.utc_now() |> DateTime.add(-5, :day) |> DateTime.truncate(:second)
    )
    |> Slipdock.Repo.update!()

    conn =
      post(conn, ~p"/api/boards/#{board.id}/cards", %{"title" => "Too late", "column" => "To Do"})

    body = json_response(conn, 402)
    assert body["error"] == "trial_expired"
    assert body["message"] =~ "subscribe"
  end

  test "GET /api/me carries every limit, so a batch can be sized first", %{conn: conn} do
    body = get(conn, ~p"/api/me") |> json_response(200)

    assert body["cards"]["limit"] == 1
    assert body["limits"]["boards"]["limit"] == 1_000
    assert body["limits"]["storage"]["limit"] == 10_240 * 1024 * 1024
    assert body["limits"]["breakdown"]["cards"] == 1
    refute body["limits"]["trial"]["applies?"]
  end
end
