defmodule SlipdockWeb.PortableAPITest do
  @moduledoc """
  Board trees out and in over HTTP.

  Two things here are about more than plumbing. An export must only ever carry
  boards the caller **owns** — a board shared with you is somebody else's to
  hand on, and an export that quietly swept it up would be a way to take a copy
  of their work. And a read-only token must be able to take an export and
  unable to push one in, which is the whole reason the scope exists.
  """
  use SlipdockWeb.ConnCase, async: false

  import Slipdock.Fixtures

  alias Slipdock.{Access, Accounts, Boards}

  defp token_conn(user, scope \\ "write") do
    {token, _} = Accounts.create_api_token(user, "test", scope: scope)
    build_conn() |> Plug.Conn.put_req_header("authorization", "Bearer " <> token)
  end

  setup do
    owner = user_fixture("owner@example.com")
    board = board_fixture(%{"name" => "Delivery", "code" => "del"}, owner: owner)
    [_backlog, todo | _] = board.columns
    _card = card_fixture(todo, %{"title" => "Ship it"})

    %{owner: owner, board: board, other: user_fixture("other@example.com")}
  end

  describe "GET /api/export" do
    test "answers with a document and what it is leaving behind", %{owner: owner} do
      body = token_conn(owner) |> get(~p"/api/export") |> json_response(200)

      assert body["export"]["slipdock_portable"] == Slipdock.Portable.format_version()
      assert [%{"root" => %{"name" => "Delivery"}}] = body["export"]["boards"]
      assert is_list(body["leaving_behind"])
    end

    test "a read-only token may take one — reading your boards out is a read", %{owner: owner} do
      assert token_conn(owner, "read") |> get(~p"/api/export") |> json_response(200)
    end

    test "no token at all gets nothing" do
      assert build_conn() |> get(~p"/api/export") |> json_response(401)
    end

    test "takes only the boards named", %{owner: owner} do
      _second = board_fixture(%{"name" => "Second"}, owner: owner)

      body = token_conn(owner) |> get(~p"/api/export?boards=del") |> json_response(200)
      assert [%{"root" => %{"name" => "Delivery"}}] = body["export"]["boards"]
    end

    test "a board that does not exist says so", %{owner: owner} do
      conn = token_conn(owner) |> get(~p"/api/export?boards=nope")
      assert json_response(conn, 404)["error"] =~ "no board"
    end

    test "archived cards come only when asked for", %{owner: owner, board: board} do
      [card] = Boards.list_cards(board, %{})
      {:ok, _} = Boards.archive_card(card)

      cards = fn query ->
        token_conn(owner)
        |> get("/api/export" <> query)
        |> json_response(200)
        |> get_in(["export", "boards"])
        |> hd()
        |> Map.fetch!("cards")
      end

      assert cards.("") == []
      assert [%{"title" => "Ship it"}] = cards.("?archived=cards")
      assert [%{"title" => "Ship it"}] = cards.("?archived=all")
    end
  end

  describe "an export is the caller's own boards, and nobody else's" do
    test "a board shared with you is not yours to export", %{board: board, other: other} do
      {:ok, _} = Access.grant(board, other, "write", board.owner)

      # They can read it, so they can see it in /api/boards …
      assert token_conn(other)
             |> get(~p"/api/boards")
             |> json_response(200)
             |> Map.fetch!("boards")
             |> Enum.any?(&(&1["name"] == "Delivery"))

      # … and still cannot take a copy of it off the server.
      conn = token_conn(other) |> get(~p"/api/export?boards=del")
      assert json_response(conn, 403)["error"] =~ "own"
    end

    test "an export with no boards named sweeps up only what you own", %{other: other} do
      body = token_conn(other) |> get(~p"/api/export") |> json_response(200)
      assert body["export"]["boards"] == []
    end
  end

  describe "POST /api/import" do
    test "the document from an export goes straight back in", %{owner: owner} do
      document = token_conn(owner) |> get(~p"/api/export") |> json_response(200)

      body =
        token_conn(owner)
        |> post(~p"/api/import", document)
        |> json_response(200)

      assert body["imported"]["cards"] == 1
      assert [%{"name" => "Delivery"}] = body["imported"]["boards"]
    end

    test "a bare document works too, not only a whole response", %{owner: owner} do
      %{"export" => document} =
        token_conn(owner) |> get(~p"/api/export") |> json_response(200)

      assert token_conn(owner)
             |> post(~p"/api/import", document)
             |> json_response(200)
             |> get_in(["imported", "cards"]) == 1
    end

    test "a read-only token may not push one in", %{owner: owner} do
      document = token_conn(owner) |> get(~p"/api/export") |> json_response(200)

      conn = token_conn(owner, "read") |> post(~p"/api/import", document)
      assert json_response(conn, 403)["error"] =~ "read-only"
    end

    test "something that is not one of ours says what is missing", %{owner: owner} do
      conn = token_conn(owner) |> post(~p"/api/import", %{"boards" => []})
      assert json_response(conn, 422)["error"] =~ "slipdock_portable"
    end

    test "a format version this build does not read", %{owner: owner} do
      conn =
        token_conn(owner)
        |> post(~p"/api/import", %{"slipdock_portable" => 99, "boards" => []})

      assert json_response(conn, 422)["error"] =~ "version 99"
    end

    test "a document that will not fit says so, and builds nothing", %{
      owner: owner,
      board: board
    } do
      # Two cards in the document, room for one — and the limit set only after
      # they exist, so it is the import that hits it rather than the fixture.
      [_backlog, todo | _] = Boards.get_board!(board.id).columns
      _second = card_fixture(todo, %{"title" => "And another"})

      {:ok, _} = Slipdock.Settings.complete_setup(%{"admin_email" => "a@example.com"})
      {:ok, _} = Slipdock.Settings.update(%{"free_card_limit" => 1})

      document = token_conn(owner) |> get(~p"/api/export") |> json_response(200)
      receiver = user_fixture("receiver@example.com")

      conn = token_conn(receiver) |> post(~p"/api/import", document)
      error = json_response(conn, 422)["error"]

      assert error =~ "Nothing was imported"
      assert Boards.find_board("del-2") == {:error, :not_found}
    end
  end
end
