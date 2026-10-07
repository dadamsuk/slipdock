defmodule SlipdockWeb.API.CustomListsTest do
  @moduledoc "POST /api/boards with lists of its own, and `save_template`."
  use SlipdockWeb.ConnCase, async: true

  alias Slipdock.Boards

  setup %{conn: conn} do
    %{
      conn: put_req_header(conn, "accept", "application/json"),
      name: "API lists #{System.unique_integer([:positive])}"
    }
  end

  defp list_names(body), do: Enum.map(body["board"]["columns"], & &1["name"])

  test "columns sets the lists, names or maps", %{conn: conn} do
    body =
      conn
      |> post(~p"/api/boards", %{
        "name" => "Pipeline",
        "columns" => ["Ideas", %{"name" => "Doing", "wip_limit" => 2}, "Done"]
      })
      |> json_response(201)

    assert list_names(body) == ["Ideas", "Doing", "Done"]

    board = Boards.get_board!(body["board"]["id"])
    assert Enum.map(board.columns, & &1.category) == [nil, "doing", "done"]
    assert board.template_id == nil
  end

  test "save_template keeps them as a template", %{conn: conn, name: name} do
    body =
      conn
      |> post(~p"/api/boards", %{
        "name" => "Kept",
        "columns" => ["A", "B"],
        "save_template" => name
      })
      |> json_response(201)

    assert {:ok, t} = Boards.find_template(name)
    assert Enum.map(t.columns, & &1["name"]) == ["A", "B"]
    assert Boards.get_board!(body["board"]["id"]).template_id == t.id
  end

  test "save_template true uses the board's name; false saves nothing", %{conn: conn, name: name} do
    conn
    |> post(~p"/api/boards", %{"name" => name, "columns" => ["A"], "save_template" => true})
    |> json_response(201)

    assert {:ok, _} = Boards.find_template(name)

    other = name <> " b"

    conn
    |> post(~p"/api/boards", %{"name" => other, "columns" => ["A"], "save_template" => "false"})
    |> json_response(201)

    assert {:error, :not_found} = Boards.find_template(other)
  end

  test "an empty list of lists is a 422 naming columns", %{conn: conn} do
    body =
      conn
      |> post(~p"/api/boards", %{"name" => "None", "columns" => []})
      |> json_response(422)

    assert body["details"]["columns"] == ["add at least one list"]
  end

  test "a taken template name is a 422 and makes no board", %{conn: conn, user: user, name: name} do
    {:ok, _} = Boards.create_template(%{"name" => name, "columns" => ["X"]})

    body =
      conn
      |> post(~p"/api/boards", %{"name" => "Clash", "columns" => ["A"], "save_template" => name})
      |> json_response(422)

    assert body["details"]["save_template"] == ["a template called “#{name}” already exists"]
    assert Slipdock.Access.list_boards(user) == []
  end
end
