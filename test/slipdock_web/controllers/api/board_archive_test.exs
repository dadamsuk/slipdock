defmodule SlipdockWeb.API.BoardArchiveTest do
  @moduledoc "Archiving boards and setting the caller's own board order over the API."
  use SlipdockWeb.ConnCase, async: true

  import Slipdock.Fixtures
  alias Slipdock.{Access, Boards}

  setup %{conn: conn, user: user} do
    conn = put_req_header(conn, "accept", "application/json")

    %{
      conn: conn,
      a: board_fixture(%{"name" => "Alpha"}, owner: user),
      b: board_fixture(%{"name" => "Bravo"}, owner: user),
      c: board_fixture(%{"name" => "Charlie"}, owner: user)
    }
  end

  defp names(body), do: Enum.map(body["boards"], & &1["name"])

  test "archiving takes a board out of the listing, and restoring brings it back", ctx do
    %{conn: conn, b: b} = ctx

    assert %{"board" => %{"archived_at" => at}} =
             conn |> post(~p"/api/boards/#{b.id}/archive") |> json_response(200)

    assert at

    body = conn |> get(~p"/api/boards") |> json_response(200)
    assert names(body) == ["Alpha", "Charlie"]

    body = conn |> get(~p"/api/boards?archived=true") |> json_response(200)
    assert names(body) == ["Bravo"]

    body = conn |> get(~p"/api/boards?archived=all") |> json_response(200)
    assert names(body) == ["Alpha", "Bravo", "Charlie"]

    # The board itself still reads and writes.
    assert %{"board" => %{"name" => "Bravo"}} =
             conn |> get(~p"/api/boards/#{b.id}") |> json_response(200)

    assert %{"board" => %{"archived_at" => nil}} =
             conn |> post(~p"/api/boards/#{b.id}/restore") |> json_response(200)

    assert names(conn |> get(~p"/api/boards") |> json_response(200)) ==
             ["Alpha", "Bravo", "Charlie"]
  end

  test "only the owner may archive a board", %{conn: conn, user: user} do
    other = user_fixture("other@example.com")
    shared = board_fixture(%{"name" => "Shared"}, owner: other)
    {:ok, _} = Access.grant(shared, user, "write", other)

    assert %{"error" => error} =
             conn |> post(~p"/api/boards/#{shared.id}/archive") |> json_response(403)

    assert error =~ "forbidden"
    refute Slipdock.Boards.Board.archived?(Boards.get_board!(shared.id))
  end

  test "a sub-board cannot be archived", %{conn: conn, a: a} do
    card = card_fixture(hd(a.columns))
    {:ok, template} = Boards.find_template("Simple")
    {:ok, sub} = Boards.create_sub_board(card, template)

    assert conn |> post(~p"/api/boards/#{sub.id}/archive") |> json_response(422)
  end

  describe "the order" do
    test "is set by the caller and read back in listings", ctx do
      %{conn: conn, a: a, b: b, c: c} = ctx

      body =
        conn
        |> post(~p"/api/boards/order", %{"boards" => [c.code, b.id, "Alpha"]})
        |> json_response(200)

      assert names(body) == ["Charlie", "Bravo", "Alpha"]
      assert names(conn |> get(~p"/api/boards") |> json_response(200)) == names(body)

      # …and another sort can be asked for without disturbing it.
      assert names(conn |> get(~p"/api/boards?sort=name") |> json_response(200)) ==
               ["Alpha", "Bravo", "Charlie"]

      assert names(conn |> get(~p"/api/boards") |> json_response(200)) ==
               ["Charlie", "Bravo", "Alpha"]

      assert Boards.board_order(ctx.user) == %{c.id => 0, b.id => 1, a.id => 2}
    end

    test "boards left out fall to the end", %{conn: conn, a: a, c: c} do
      body = conn |> post(~p"/api/boards/order", %{"boards" => [c.id]}) |> json_response(200)
      assert names(body) == ["Charlie", "Alpha", "Bravo"]
      assert hd(body["boards"])["id"] == c.id
      refute a.id == hd(body["boards"])["id"]
    end

    test "a board the caller cannot see is refused", %{conn: conn, a: a} do
      other = user_fixture("other@example.com")
      theirs = board_fixture(%{"name" => "Theirs"}, owner: other)

      assert %{"error" => error} =
               conn
               |> post(~p"/api/boards/order", %{"boards" => [theirs.id, a.id]})
               |> json_response(403)

      assert error =~ "Theirs"
      assert Boards.board_order(other) == %{}
    end

    test "an unknown board is a 404, and a missing list a bad request", %{conn: conn} do
      assert conn
             |> post(~p"/api/boards/order", %{"boards" => ["nope"]})
             |> json_response(404)

      assert conn |> post(~p"/api/boards/order", %{}) |> json_response(400)
    end
  end
end
