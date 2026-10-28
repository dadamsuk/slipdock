defmodule SlipdockWeb.MultiboardAPITest do
  @moduledoc """
  The multiboard overview without the UI (#1479): `GET /api/multiboard`
  takes lists by id or `board/list`, falls back on the remembered view, and
  keeps to what the token can reach.
  """
  use SlipdockWeb.ConnCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Accounts, Multiboard}

  setup %{user: user} do
    ops = board_fixture(%{"name" => "Ops"}, owner: user)
    web = board_fixture(%{"name" => "Web"}, owner: user)
    [_, ops_todo, _, _] = ops.columns
    [_, web_todo, _, _] = web.columns
    card_fixture(ops_todo, %{"title" => "Fix the pager"})
    card_fixture(ops_todo, %{"title" => "Rotate keys"})
    card_fixture(web_todo, %{"title" => "Landing page"})
    %{ops: ops, web: web, ops_todo: ops_todo, web_todo: web_todo}
  end

  defp with_token(user, opts \\ []) do
    {token, _} = Accounts.create_api_token(user, "laptop", opts)

    build_conn()
    |> put_req_header("accept", "application/json")
    |> put_req_header("authorization", "Bearer " <> token)
  end

  test "lists by id and by board/list, laid out by list", %{user: user} = ctx do
    body =
      with_token(user)
      |> get(
        ~p"/api/multiboard?#{[lists: "#{ctx.ops_todo.id},#{ctx.web.code}/to do", top: 1, by: "list"]}"
      )
      |> json_response(200)

    assert body["top"] == 1
    assert body["by"] == "list"

    assert Enum.map(body["lists"], & &1["id"]) |> Enum.sort() ==
             Enum.sort([ctx.ops_todo.id, ctx.web_todo.id])

    labels = Enum.map(body["sections"], & &1["label"])
    assert "Ops › To Do" in labels and "Web › To Do" in labels

    ops = Enum.find(body["sections"], &(&1["label"] == "Ops › To Do"))
    assert [%{"title" => "Fix the pager", "column" => "To Do", "board" => code}] = ops["cards"]
    assert code == ctx.ops.code
  end

  test "no lists given: the remembered view, which the API leaves alone", %{user: user} = ctx do
    {:ok, _} = Multiboard.save_prefs(user, %{lists: [ctx.web_todo.id], top: 5, by: "grid"})

    body = with_token(user) |> get(~p"/api/multiboard") |> json_response(200)
    assert body["by"] == "grid"
    assert [%{"key" => "grid", "cards" => [%{"title" => "Landing page"}]}] = body["sections"]

    with_token(user)
    |> get(~p"/api/multiboard?#{[lists: "#{ctx.ops_todo.id}"]}")
    |> json_response(200)

    assert Multiboard.prefs(Slipdock.Repo.reload(user)).lists == [ctx.web_todo.id]
  end

  test "an unknown list is a 404 naming it", %{user: user} do
    conn = with_token(user) |> get(~p"/api/multiboard?#{[lists: "ops/Nowhere"]}")
    assert json_response(conn, 404)["error"] =~ "ops/Nowhere"
  end

  test "a token confined to one board can't name another's lists", %{user: user} = ctx do
    conn = with_token(user, scope_boards: [ctx.web.id])
    assert get(conn, ~p"/api/multiboard?#{[lists: "#{ctx.ops_todo.id}"]}") |> json_response(404)

    body = get(conn, ~p"/api/multiboard?#{[lists: "#{ctx.web_todo.id}"]}") |> json_response(200)
    assert [%{"label" => "Web"}] = body["sections"]
  end
end
