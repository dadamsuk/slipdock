defmodule SlipdockWeb.MultiboardsAPITest do
  @moduledoc """
  Saved multiboards without the UI (#1482): `/api/multiboards` lists,
  saves, shows, changes and deletes the caller's own, and nobody else's.
  """
  use SlipdockWeb.ConnCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Accounts, Multiboard, Repo}

  setup %{user: user} do
    ops = board_fixture(%{"name" => "Ops", "code" => "opmba"}, owner: user)
    [_, todo, doing, _] = ops.columns
    card_fixture(todo, %{"title" => "Fix the pager"})
    %{ops: ops, todo: todo, doing: doing}
  end

  defp with_token(user, opts \\ []) do
    {token, _} = Accounts.create_api_token(user, "laptop", opts)

    build_conn()
    |> put_req_header("accept", "application/json")
    |> put_req_header("authorization", "Bearer " <> token)
  end

  defp saved(user, name, lists \\ []) do
    {:ok, s} = Multiboard.create_saved(user, %{"name" => name}, %{lists: lists})
    s
  end

  test "POST saves one by name and colour, with lists as board/list", %{user: user} = ctx do
    body =
      with_token(user)
      |> post(~p"/api/multiboards", %{
        "name" => "Ops queue",
        "color" => "rose",
        "lists" => "opmba/to do,#{ctx.doing.id}",
        "top" => "2",
        "by" => "grid"
      })
      |> json_response(201)

    assert %{"name" => "Ops queue", "color" => "rose", "top" => 2, "by" => "grid"} =
             body["multiboard"]

    assert body["multiboard"]["lists"] == [ctx.todo.id, ctx.doing.id]
    assert [%{name: "Ops queue"}] = Multiboard.list_saved(user)
  end

  test "POST takes lists as an array, and the remembered view when there are none",
       %{user: user} = ctx do
    {:ok, user} = Multiboard.save_prefs(user, %{lists: [ctx.doing.id], top: 4, by: "list"})

    body =
      with_token(user)
      |> post(~p"/api/multiboards", %{"name" => "Remembered"})
      |> json_response(201)

    assert %{"lists" => [id], "top" => 4, "by" => "list", "color" => "indigo"} =
             body["multiboard"]

    assert id == ctx.doing.id

    body =
      with_token(user)
      |> post(~p"/api/multiboards", %{"name" => "Array", "lists" => [ctx.todo.id]})
      |> json_response(201)

    assert body["multiboard"]["lists"] == [ctx.todo.id]
  end

  test "POST refuses an unknown list, a blank name and an unknown colour", %{user: user} do
    conn = with_token(user)

    assert %{"error" => "list \"opmba/nope\" not found"} =
             conn
             |> post(~p"/api/multiboards", %{"name" => "X", "lists" => "opmba/nope"})
             |> json_response(404)

    assert %{"details" => %{"name" => _}} =
             conn |> post(~p"/api/multiboards", %{"name" => ""}) |> json_response(422)

    assert %{"details" => %{"color" => _}} =
             conn
             |> post(~p"/api/multiboards", %{"name" => "X", "color" => "plaid"})
             |> json_response(422)

    assert Multiboard.list_saved(user) == []
  end

  test "GET lists them; GET one shows its cards, by id or name", %{user: user} = ctx do
    mb = saved(user, "Pager", [ctx.todo.id])
    saved(user, "Another")

    assert %{"multiboards" => [%{"name" => "Another"}, %{"name" => "Pager"}]} =
             with_token(user) |> get(~p"/api/multiboards") |> json_response(200)

    for ref <- [to_string(mb.id), "pager"] do
      body = with_token(user) |> get(~p"/api/multiboards/#{ref}") |> json_response(200)
      assert body["multiboard"]["id"] == mb.id
      assert [%{"cards" => [%{"title" => "Fix the pager"}]}] = body["sections"]
    end
  end

  test "PATCH renames, recolours and changes the view; DELETE removes it",
       %{user: user} = ctx do
    mb = saved(user, "Old", [ctx.todo.id])
    conn = with_token(user)

    body =
      conn
      |> patch(~p"/api/multiboards/#{mb.id}", %{"name" => "New", "color" => "teal", "top" => 9})
      |> json_response(200)

    # Lists left out stay as they were.
    assert %{"name" => "New", "color" => "teal", "top" => 9, "lists" => [id]} = body["multiboard"]
    assert id == ctx.todo.id

    body =
      conn
      |> patch(~p"/api/multiboards/#{mb.id}", %{"lists" => "#{ctx.doing.id}", "by" => "grid"})
      |> json_response(200)

    assert %{"lists" => [doing], "by" => "grid", "top" => 9} = body["multiboard"]
    assert doing == ctx.doing.id

    assert %{"details" => %{"color" => _}} =
             conn
             |> patch(~p"/api/multiboards/#{mb.id}", %{"color" => "plaid"})
             |> json_response(422)

    assert %{"deleted" => %{"name" => "New"}} =
             conn |> delete(~p"/api/multiboards/#{mb.id}") |> json_response(200)

    refute Repo.reload(mb)
  end

  test "somebody else's is not found, to read, change or delete", %{user: user} do
    stranger = user_fixture("mba-stranger@example.com")
    theirs = saved(stranger, "Theirs")
    conn = with_token(user)

    assert conn |> get(~p"/api/multiboards") |> json_response(200) == %{"multiboards" => []}
    assert conn |> get(~p"/api/multiboards/#{theirs.id}") |> json_response(404)

    assert conn
           |> patch(~p"/api/multiboards/#{theirs.id}", %{"name" => "Mine"})
           |> json_response(404)

    assert conn |> delete(~p"/api/multiboards/#{theirs.id}") |> json_response(404)
    assert Repo.reload(theirs).name == "Theirs"
  end

  test "a read-only token can look but not save", %{user: user} do
    conn = with_token(user, scope: "read")
    assert conn |> get(~p"/api/multiboards") |> json_response(200)
    assert conn |> post(~p"/api/multiboards", %{"name" => "No"}) |> response(403)
    assert Multiboard.list_saved(user) == []
  end
end
