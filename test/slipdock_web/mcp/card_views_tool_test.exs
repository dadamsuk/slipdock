defmodule SlipdockWeb.MCP.CardViewsToolTest do
  @moduledoc """
  `card_views` (#2031): the caller's own card views over MCP, each action
  through `tools/call` as a client makes it, and the refusals: another
  person's view, an element that isn't one, a list without its board, a
  board the caller can't read, and Show all anywhere but a board's level.
  """
  use SlipdockWeb.ConnCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Accounts, Boards, CardViews}

  setup %{user: user} do
    board = board_fixture(%{"name" => "View Desk", "code" => "vd7"}, owner: user)
    [_backlog, doing | _] = board.columns
    %{board: board, doing: doing}
  end

  defp call(conn, args) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post(
      "/mcp",
      Jason.encode!(%{
        jsonrpc: "2.0",
        id: 1,
        method: "tools/call",
        params: %{name: "card_views", arguments: args}
      })
    )
    |> json_response(200)
    |> Map.fetch!("result")
  end

  defp ok!(result) do
    assert result["isError"] == false, inspect(result["content"])
    result["structuredContent"]
  end

  defp error!(result) do
    assert result["isError"] == true, inspect(result)
    [%{"text" => text}] = result["content"]
    text
  end

  defp token_conn(user, scope \\ "write") do
    {token, _} = Accounts.create_api_token(user, "mcp", scope: scope)
    build_conn() |> put_req_header("authorization", "Bearer " <> token)
  end

  describe "named card views" do
    test "create, list, get, update and delete one", %{conn: conn, user: user} do
      created =
        ok!(call(conn, %{action: "create", name: "Focus", hide: ["tags"], show: ["due_date"]}))[
          "card_view"
        ]

      assert created["name"] == "Focus"
      assert created["elements"] == %{"tags" => false, "due_date" => true}

      listed = ok!(call(conn, %{action: "list"}))
      assert [%{"name" => "Focus", "id" => id}] = listed["card_views"]
      assert id == created["id"]

      assert %{"key" => "side.time", "group" => "side"} =
               Enum.find(listed["elements"], &(&1["key"] == "side.time"))

      got = ok!(call(conn, %{action: "get", view: "Focus"}))["card_view"]
      assert got["id"] == id

      updated =
        ok!(
          call(conn, %{
            action: "update",
            view: to_string(id),
            name: "Calm",
            inherit: ["tags"],
            elements: %{"handoff_note" => false}
          })
        )["card_view"]

      assert updated["name"] == "Calm"
      assert updated["elements"] == %{"due_date" => true, "handoff_note" => false}

      reset = ok!(call(conn, %{action: "update", view: "Calm", reset: true}))["card_view"]
      assert reset["elements"] == %{}

      assert ok!(call(conn, %{action: "delete", view: "Calm"}))["deleted"]["id"] == id
      assert CardViews.list(user) == []
    end

    test "another person's view is not found, to get, change or delete", %{conn: conn} do
      other = user_fixture("other@example.com")
      {:ok, theirs} = CardViews.create(other, %{"name" => "Theirs"})

      for action <- ~w(get update delete), ref <- [to_string(theirs.id), "Theirs"] do
        assert error!(call(conn, %{action: action, view: ref, name: "Mine"})) =~
                 "no card view of yours"
      end

      assert {:ok, %{name: "Theirs"}} = CardViews.get(other, theirs.id)
    end

    test "an element that isn't one is named in the refusal, and nothing is saved", %{
      conn: conn,
      user: user
    } do
      assert error!(call(conn, %{action: "create", name: "X", hide: ["colour"]})) =~
               "not an element: colour"

      assert error!(call(conn, %{action: "create", name: "X", elements: %{"nope" => true}})) =~
               "not an element: nope"

      assert CardViews.list(user) == []
    end

    test "a duplicate name and a missing one are refused", %{conn: conn} do
      ok!(call(conn, %{action: "create", name: "Focus"}))
      assert error!(call(conn, %{action: "create", name: "Focus"})) =~ "not saved: name"
      assert error!(call(conn, %{action: "create"})) =~ "name is required"
      assert error!(call(conn, %{action: "get"})) =~ "view is required"
    end

    test "an unknown action says which there are", %{conn: conn} do
      assert error!(call(conn, %{action: "explode"})) =~ "action must be one of list, get"
    end
  end

  describe "levels" do
    test "global level: set, read and clear", %{conn: conn} do
      level = ok!(call(conn, %{action: "set_level", hide: ["tags"]}))["level"]
      assert level["level"] == "global"
      assert level["board"] == nil
      assert level["elements"] == %{"tags" => false}

      assert ok!(call(conn, %{action: "level"}))["level"]["elements"] == %{"tags" => false}

      cleared = ok!(call(conn, %{action: "clear_level"}))["level"]
      assert cleared["elements"] == %{}
    end

    test "a board's level applies a named view and turns Show all on, then none", %{
      conn: conn,
      board: board
    } do
      ok!(call(conn, %{action: "create", name: "Focus", hide: ["tags"]}))

      level =
        ok!(call(conn, %{action: "set_level", board: "vd7", apply: "Focus", show_all: true}))[
          "level"
        ]

      assert level["level"] == "board"
      assert level["board"]["id"] == board.id
      assert level["card_view"]["name"] == "Focus"
      assert level["show_all"] == true

      level = ok!(call(conn, %{action: "set_level", board: "vd7", apply: nil}))["level"]
      assert level["card_view"] == nil
      assert level["show_all"] == true
    end

    test "a list's level, by the list's name", %{conn: conn, doing: doing} do
      level =
        ok!(call(conn, %{action: "set_level", board: "vd7", list: doing.name, show: ["age"]}))[
          "level"
        ]

      assert level["level"] == "list"
      assert level["list"] == %{"id" => doing.id, "name" => doing.name}
      assert level["elements"] == %{"age" => true}

      read = ok!(call(conn, %{action: "level", board: "vd7", list: to_string(doing.id)}))
      assert read["level"]["elements"] == %{"age" => true}

      ok!(call(conn, %{action: "clear_level", board: "vd7", list: doing.name}))

      assert ok!(call(conn, %{action: "level", board: "vd7", list: doing.name}))["level"][
               "elements"
             ] == %{}
    end

    test "Show all is refused on a list's level and the global one", %{conn: conn, doing: doing} do
      assert error!(
               call(conn, %{action: "set_level", board: "vd7", list: doing.name, show_all: true})
             ) =~ "show_all is a board's switch"

      assert error!(call(conn, %{action: "set_level", show_all: true})) =~
               "show_all is a board's switch"
    end

    test "a list without a board, a list not on it, and an unknown view are refused", %{
      conn: conn
    } do
      assert error!(call(conn, %{action: "level", list: "Doing"})) =~ "list needs a board"
      assert error!(call(conn, %{action: "level", board: "vd7", list: "Nowhere"})) =~ "no list"

      assert error!(call(conn, %{action: "set_level", board: "vd7", apply: "Nope"})) =~
               "no card view of yours"
    end

    test "a board the caller can't read is not found, at every level action" do
      stranger = user_fixture("stranger@example.com")
      conn = token_conn(stranger)

      for action <- ~w(level set_level clear_level applied) do
        assert error!(call(conn, %{action: action, board: "vd7", hide: ["tags"]})) =~
                 "no board you can see",
               action
      end
    end
  end

  describe "applied" do
    test "each element with its source, the saved view's card view on top", %{
      conn: conn,
      board: board,
      doing: doing
    } do
      ok!(call(conn, %{action: "create", name: "Quiet", hide: ["due_date"]}))
      ok!(call(conn, %{action: "set_level", hide: ["tags"]}))
      ok!(call(conn, %{action: "set_level", board: "vd7", list: doing.name, show: ["tags"]}))

      {:ok, _} =
        Boards.SavedViews.create_saved_view(board, %{
          "name" => "Mine",
          "config" => %{"card_view" => "Quiet"}
        })

      applied =
        ok!(call(conn, %{action: "applied", board: "vd7", list: doing.name, saved_view: "Mine"}))

      assert applied["board"]["code"] == "vd7"
      assert applied["list"]["name"] == doing.name
      assert applied["saved_view_card_view"] == "Quiet"

      by_key = Map.new(applied["elements"], &{&1["key"], &1})
      assert %{"shown" => true, "source" => "list"} = by_key["tags"]
      assert %{"shown" => false, "source" => "saved view"} = by_key["due_date"]
      assert %{"source" => "default"} = by_key["side.time"]
    end

    test "with no board it is the global level alone", %{conn: conn} do
      ok!(call(conn, %{action: "set_level", hide: ["tags"]}))
      applied = ok!(call(conn, %{action: "applied"}))

      assert applied["board"] == nil
      tags = Enum.find(applied["elements"], &(&1["key"] == "tags"))
      assert %{"shown" => false, "source" => "global"} = tags

      assert error!(call(conn, %{action: "applied", saved_view: "Mine"})) =~
               "saved_view needs a board"
    end

    test "a saved view that isn't on the board is refused", %{conn: conn} do
      assert error!(call(conn, %{action: "applied", board: "vd7", saved_view: "Nope"})) =~
               "no saved view Nope"
    end
  end

  test "a read-only token may read card views but not change them", %{user: user} do
    conn = token_conn(user, "read")

    assert ok!(call(conn, %{action: "list"}))["card_views"] == []
    assert ok!(call(conn, %{action: "level"}))["level"]["level"] == "global"
    assert error!(call(conn, %{action: "create", name: "X"})) =~ "read-only"
    assert error!(call(conn, %{action: "set_level", hide: ["tags"]})) =~ "read-only"
  end
end
