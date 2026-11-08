defmodule SlipdockWeb.API.CardViewsTest do
  @moduledoc "The caller's own card views over REST (#2031): /api/card-views."
  use SlipdockWeb.ConnCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Accounts, CardViews}

  setup %{conn: conn, user: user} do
    board = board_fixture(%{"name" => "Plan"}, owner: user)

    %{
      conn: put_req_header(conn, "accept", "application/json"),
      board: board,
      todo: hd(board.columns)
    }
  end

  defp stranger do
    user_fixture("stranger-#{System.unique_integer([:positive])}@example.com")
  end

  test "lists named views and the element catalogue", %{conn: conn, user: user} do
    {:ok, _} = CardViews.create(user, %{"name" => "Lean", "hide" => "tags"})

    body = conn |> get(~p"/api/card-views") |> json_response(200)
    assert [%{"name" => "Lean", "elements" => %{"tags" => false}}] = body["card_views"]
    keys = Map.new(body["elements"], &{&1["key"], &1})
    assert %{"group" => "front", "default" => true} = keys["tags"]
    assert %{"group" => "open", "default" => true} = keys["open.description"]
    assert %{"group" => "side"} = keys["side.time"]
    # The sidebar's properties are elements too (#2070).
    assert %{"group" => "side", "label" => "Assignees and runner", "default" => true} =
             keys["side.assignees"]

    assert %{"default" => false} = keys["handoff_note"]
  end

  test "creates, reads, changes and deletes a named view", %{conn: conn} do
    assert %{"card_view" => %{"id" => id, "name" => "Lean", "elements" => elements}} =
             conn
             |> post(~p"/api/card-views", %{name: "Lean", show: ["id"], hide: "tags,due_date"})
             |> json_response(201)

    assert elements == %{"id" => true, "tags" => false, "due_date" => false}

    assert %{"card_view" => %{"id" => ^id}} =
             conn |> get(~p"/api/card-views/Lean") |> json_response(200)

    assert %{"card_view" => %{"name" => "Leaner", "elements" => %{"id" => true}}} =
             conn
             |> patch(~p"/api/card-views/#{id}", %{
               name: "Leaner",
               elements: %{"tags" => nil},
               inherit: ["due_date"]
             })
             |> json_response(200)

    {:ok, _} =
      CardViews.update_level(conn.assigns[:current_user] || user_fixture(), :global, %{
        "card_view" => id
      })

    assert %{"deleted" => %{"id" => ^id}, "levels_now_inheriting" => 1} =
             conn |> delete(~p"/api/card-views/#{id}") |> json_response(200)

    assert %{"error" => "card view not found"} =
             conn |> get(~p"/api/card-views/#{id}") |> json_response(404)
  end

  test "refuses unknown elements, duplicate names and other people's views", %{
    conn: conn,
    user: user
  } do
    assert %{"error" => "not an element: bogus" <> _} =
             conn |> post(~p"/api/card-views", %{name: "X", show: "bogus"}) |> json_response(422)

    {:ok, _} = CardViews.create(user, %{"name" => "Twice"})

    assert %{"details" => %{"name" => ["you already have a card view of that name"]}} =
             conn |> post(~p"/api/card-views", %{name: "Twice"}) |> json_response(422)

    {:ok, theirs} = CardViews.create(stranger(), %{"name" => "Theirs"})
    assert conn |> get(~p"/api/card-views/#{theirs.id}") |> json_response(404)
    assert conn |> patch(~p"/api/card-views/#{theirs.id}", %{name: "Mine"}) |> json_response(404)
    assert conn |> delete(~p"/api/card-views/#{theirs.id}") |> json_response(404)
  end

  test "reads, sets and clears each level", %{conn: conn, user: user, board: board, todo: todo} do
    {:ok, _} = CardViews.create(user, %{"name" => "Lean", "hide" => "tags"})

    assert %{"level" => %{"level" => "global", "board" => nil, "elements" => %{}}} =
             conn |> get(~p"/api/card-views/level") |> json_response(200)

    assert %{
             "level" => %{
               "level" => "board",
               "show_all" => true,
               "card_view" => %{"name" => "Lean"}
             }
           } =
             conn
             |> put(~p"/api/card-views/level", %{
               board: board.code,
               card_view: "Lean",
               show_all: true
             })
             |> json_response(200)

    # A list by its name, on the board named by its id.
    assert %{
             "level" => %{
               "level" => "list",
               "list" => %{"id" => list_id},
               "elements" => %{"id" => true}
             }
           } =
             conn
             |> patch(~p"/api/card-views/level", %{board: board.id, list: todo.name, show: "id"})
             |> json_response(200)

    assert list_id == todo.id

    assert %{"level" => %{"elements" => %{}}} =
             conn
             |> delete(~p"/api/card-views/level?#{[board: board.id, list: todo.id]}")
             |> json_response(200)

    assert %{"level" => %{"card_view" => nil}} =
             conn
             |> put(~p"/api/card-views/level", %{board: board.id, card_view: nil})
             |> json_response(200)
  end

  test "level errors: a list without its board, unknown lists, boards and views, show_all off a board",
       %{conn: conn, board: board} do
    assert %{"error" => "list needs a board"} =
             conn |> get(~p"/api/card-views/level?list=1") |> json_response(400)

    assert %{"error" => "list not found"} =
             conn
             |> get(~p"/api/card-views/level?#{[board: board.id, list: "Nowhere"]}")
             |> json_response(404)

    assert %{"error" => "board not found"} =
             conn |> get(~p"/api/card-views/level?board=no-such-board") |> json_response(404)

    assert %{"error" => "card view not found"} =
             conn |> put(~p"/api/card-views/level", %{card_view: "Gone"}) |> json_response(404)

    assert %{"error" => "show_all is a board's switch" <> _} =
             conn |> put(~p"/api/card-views/level", %{show_all: true}) |> json_response(422)

    assert %{"error" => "not an element: nope" <> _} =
             conn |> put(~p"/api/card-views/level", %{hide: "nope"}) |> json_response(422)
  end

  test "a board the caller can't read is not found", %{board: board} do
    conn = stranger() |> conn_as() |> put_req_header("accept", "application/json")

    assert %{"error" => "board not found"} =
             conn
             |> put(~p"/api/card-views/level", %{board: board.id, hide: "tags"})
             |> json_response(404)

    assert conn |> get(~p"/api/card-views/applied?board=#{board.id}") |> json_response(404)
  end

  test "applied says what shows and why, with a saved view's card view on top",
       %{conn: conn, user: user, board: board, todo: todo} do
    {:ok, _} = CardViews.update_level(user, :global, %{"hide" => "tags"})
    {:ok, _} = CardViews.update_level(user, {:list, board, todo}, %{"show" => "id"})
    {:ok, _} = CardViews.create(user, %{"name" => "Top", "show" => "comments"})

    {:ok, saved} =
      Slipdock.Boards.create_saved_view(board, %{
        "name" => "Busy",
        "config" => %{"card_view" => "Top"}
      })

    body =
      conn
      |> get(~p"/api/card-views/applied?#{[board: board.code, list: todo.id, view: saved.id]}")
      |> json_response(200)

    assert body["list"]["id"] == todo.id
    assert body["saved_view_card_view"] == "Top"
    by_key = Map.new(body["elements"], &{&1["key"], &1})
    assert %{"shown" => false, "source" => "global"} = by_key["tags"]
    assert %{"shown" => true, "source" => "list"} = by_key["id"]
    assert %{"shown" => true, "source" => "saved view"} = by_key["comments"]

    # Without a board: the global level alone.
    body = conn |> get(~p"/api/card-views/applied") |> json_response(200)
    assert body["board"] == nil
    assert Enum.find(body["elements"], &(&1["key"] == "tags"))["source"] == "global"
  end

  test "a read-only token reads card views but can't change them", %{user: user} do
    {token, _} = Accounts.create_api_token(user, "ro", scope: "read")

    conn =
      build_conn()
      |> put_req_header("accept", "application/json")
      |> put_req_header("authorization", "Bearer " <> token)

    assert conn |> get(~p"/api/card-views") |> json_response(200)
    status = conn |> post(~p"/api/card-views", %{name: "X"}) |> Map.fetch!(:status)
    assert status == 403
    assert CardViews.list(user) == []
  end
end
