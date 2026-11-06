defmodule SlipdockWeb.QualityAPITest do
  @moduledoc """
  A board's quality numbers over REST (#1796): `GET
  /api/boards/:board/quality?days=` answers `Slipdock.Quality`'s report to
  anyone who can read the board, and refuses a board the caller can't.
  """
  use SlipdockWeb.ConnCase, async: true

  import Ecto.Query
  import Slipdock.Fixtures

  alias Slipdock.Repo
  alias Slipdock.Boards.Card

  setup %{conn: conn, user: user} do
    board = board_fixture(%{"name" => "Checked"}, owner: user)
    [_backlog, todo | _] = board.columns

    for rejections <- [0, 0, 3] do
      card = card_fixture(todo)

      Repo.update_all(from(c in Card, where: c.id == ^card.id),
        set: [
          verify_state: "accepted",
          verify_at: DateTime.add(DateTime.utc_now(:second), -2 * 86_400),
          verify_rejections: rejections
        ]
      )
    end

    %{conn: put_req_header(conn, "accept", "application/json"), board: board}
  end

  defp rest(conn, board, query \\ ""),
    do: conn |> get("/api/boards/#{board.code}/quality#{query}") |> json_response(200)

  test "answers the report, by code or id", %{conn: conn, board: board} do
    body = rest(conn, board)
    assert body["board"] == %{"id" => board.id, "code" => board.code}
    q = body["quality"]
    assert q["days"] == 30

    assert %{"accepted" => 3, "first_time_right" => 2, "rejections" => 3, "per_card" => 1.0} =
             q["verified"]

    assert [%{"title" => "unmapped", "cards" => 3}] = q["areas"]
    assert %{"jobs" => 0, "per_100" => %{"timeouts" => nil}} = q["jobs"]
    assert %{"incidents" => 0} = q["health"]
    assert %{"accepted" => 0} = q["previous"]

    assert conn |> get("/api/boards/#{board.id}/quality") |> json_response(200)
  end

  test "?days= narrows the window", %{conn: conn, board: board} do
    q = rest(conn, board, "?days=1")["quality"]
    assert q["days"] == 1
    assert q["verified"]["accepted"] == 0
    assert q["previous"]["accepted"] == 3
  end

  test "someone the board is shared with for reading may look", %{board: board} do
    reader = user_fixture("quality-reader@example.com")
    share_fixture(board, [reader], "read")

    {token, _} = Slipdock.Accounts.create_api_token(reader, "agent")

    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer " <> token)
      |> put_req_header("accept", "application/json")

    assert rest(conn, board)["quality"]["verified"]["accepted"] == 3
  end

  test "a board the caller can't read is refused", %{conn: conn} do
    theirs = board_fixture(%{"name" => "Theirs"}, owner: user_fixture("q-other@example.com"))
    assert conn |> get("/api/boards/#{theirs.code}/quality") |> json_response(404)
  end
end
