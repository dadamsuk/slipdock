defmodule SlipdockWeb.API.DependenciesTest do
  use SlipdockWeb.ConnCase, async: true

  import Slipdock.Fixtures

  setup %{conn: conn} do
    board = board_fixture()
    [backlog | _] = board.columns
    a = card_fixture(backlog, %{"title" => "A"})
    b = card_fixture(backlog, %{"title" => "B"})
    %{conn: put_req_header(conn, "accept", "application/json"), a: a, b: b}
  end

  test "add, read, reject, remove", %{conn: conn, a: a, b: b} do
    body =
      conn
      |> post(~p"/api/cards/#{a.id}/dependencies", %{"blocked_by" => b.id})
      |> json_response(200)

    assert body["card"]["blocked"] == true

    assert [%{"id" => bid, "title" => "B", "completed" => false, "archived" => false}] =
             body["card"]["blocked_by"]

    assert bid == b.id

    body = conn |> get(~p"/api/cards/#{b.id}") |> json_response(200)
    assert [%{"title" => "A"}] = body["card"]["blocks"]
    assert body["card"]["blocked"] == false

    assert %{"error" => msg} =
             conn
             |> post(~p"/api/cards/#{b.id}/dependencies", %{"blocked_by" => a.id})
             |> json_response(400)

    assert msg =~ "circular"

    assert %{"error" => _} =
             conn |> post(~p"/api/cards/#{a.id}/dependencies", %{}) |> json_response(400)

    assert %{"error" => "card not found"} =
             conn
             |> post(~p"/api/cards/#{a.id}/dependencies", %{"blocks" => 999_999})
             |> json_response(404)

    body = conn |> delete(~p"/api/cards/#{b.id}/dependencies/#{a.id}") |> json_response(200)
    assert body["card"]["blocks"] == []
  end

  describe "across boards" do
    setup %{a: a} do
      other = board_fixture(%{"name" => "Other", "code" => "otherb"})
      foreign = card_fixture(hd(other.columns), %{"title" => "Elsewhere"})
      %{other: other, foreign: foreign, home: Slipdock.Boards.get_board!(a.board_id)}
    end

    test "a dependency on a card on another board, read back with its board's code",
         %{conn: conn, a: a, foreign: foreign} do
      body =
        conn
        |> post(~p"/api/cards/#{a.id}/dependencies", %{"blocked_by" => foreign.id})
        |> json_response(200)

      assert body["card"]["blocked"] == true

      assert [%{"title" => "Elsewhere", "board" => "otherb", "hidden" => false}] =
               body["card"]["blocked_by"]

      body = conn |> get(~p"/api/cards/#{foreign.id}") |> json_response(200)
      assert [%{"title" => "A"}] = body["card"]["blocks"]

      body =
        conn |> delete(~p"/api/cards/#{a.id}/dependencies/#{foreign.id}") |> json_response(200)

      assert body["card"]["blocked_by"] == []
    end

    test "needs write on the blocked card and read on the blocker",
         %{home: home, other: other, a: a, b: b, foreign: foreign} do
      bob = user_fixture("bob-#{System.unique_integer([:positive])}@example.com")
      share_fixture(home, bob, "write")
      bob_conn = conn_as(bob) |> put_req_header("accept", "application/json")

      # Bob can't see the other board at all, so can't wait on its card.
      assert %{"error" => msg} =
               bob_conn
               |> post(~p"/api/cards/#{a.id}/dependencies", %{"blocked_by" => foreign.id})
               |> json_response(403)

      assert msg =~ "read"
      assert Slipdock.Boards.get_card!(a.id).blocked_by == []

      # Reading it is enough to wait on it...
      share_fixture(other, bob, "read")

      assert %{"card" => %{"blocked" => true}} =
               bob_conn
               |> post(~p"/api/cards/#{a.id}/dependencies", %{"blocked_by" => foreign.id})
               |> json_response(200)

      # ...but not to make it wait: that needs write on the blocked card.
      assert %{"error" => msg} =
               bob_conn
               |> post(~p"/api/cards/#{b.id}/dependencies", %{"blocks" => foreign.id})
               |> json_response(403)

      assert msg =~ "edit"
      assert Slipdock.Boards.get_card!(foreign.id).blocked_by == []
    end

    test "a reader who can't see the other board gets a hidden stub",
         %{home: home, a: a, foreign: foreign} do
      {:ok, _} = Slipdock.Boards.add_dependency(a, foreign)
      reader = user_fixture("reader-#{System.unique_integer([:positive])}@example.com")
      share_fixture(home, reader, "read")
      reader_conn = conn_as(reader) |> put_req_header("accept", "application/json")

      body = reader_conn |> get(~p"/api/cards/#{a.id}") |> json_response(200)
      assert body["card"]["blocked"] == true

      assert [
               %{
                 "id" => fid,
                 "title" => "A card you can't see",
                 "board" => nil,
                 "board_id" => nil,
                 "hidden" => true
               }
             ] = body["card"]["blocked_by"]

      assert fid == foreign.id
      refute Jason.encode!(body) =~ "Elsewhere"

      # The whole board and the card list hide it the same way.
      board = reader_conn |> get(~p"/api/boards/#{home.id}") |> json_response(200)
      refute Jason.encode!(board) =~ "Elsewhere"
      cards = reader_conn |> get(~p"/api/boards/#{home.id}/cards") |> json_response(200)
      refute Jason.encode!(cards) =~ "Elsewhere"
      assert Enum.any?(cards["cards"], &(&1["blocked"] and &1["title"] == "A"))
    end

    test "a token scoped to one board hides cards on the other",
         %{user: user, a: a, foreign: foreign, home: home} do
      {:ok, _} = Slipdock.Boards.add_dependency(a, foreign)
      {token, _} = Slipdock.Accounts.create_api_token(user, "scoped", scope_boards: [home.id])

      body =
        build_conn()
        |> put_req_header("authorization", "Bearer " <> token)
        |> put_req_header("accept", "application/json")
        |> get(~p"/api/cards/#{a.id}")
        |> json_response(200)

      assert [%{"hidden" => true}] = body["card"]["blocked_by"]
    end
  end
end
