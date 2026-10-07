defmodule SlipdockWeb.API.TokenScopeTest do
  @moduledoc """
  An API token's scope, enforced. Two layers, and both are tested here
  because each covers what the other cannot:

    * the pipeline guard refuses any state-changing request from a read-only
      token, including ones that never reach a board (a new board, a
      favourite, a template, an AI key);
    * `Slipdock.Access.narrow/3` confines a token to named boards and caps
      what it may do on them, with a refusal that says the scope was the
      cause.

  A scope only ever narrows. It can never grant access the user lacks.
  """
  use SlipdockWeb.ConnCase, async: true

  alias Slipdock.{Access, Accounts, Boards}

  setup %{conn: conn, user: user} do
    {:ok, board} = Boards.create_board(%{"name" => "Delivery"}, owner_id: user.id)
    board = Boards.get_board!(board.id)
    {:ok, card} = Boards.create_card(hd(board.columns), %{"title" => "A card"})
    %{conn: conn, user: user, board: board, card: card}
  end

  defp with_token(conn, user, opts) do
    {token, _} = Accounts.create_api_token(user, "agent", opts)

    conn
    |> Plug.Conn.put_req_header("authorization", "Bearer " <> token)
    |> Plug.Conn.put_req_header("content-type", "application/json")
  end

  describe "a read-only token" do
    test "reads a board", ctx do
      conn = with_token(ctx.conn, ctx.user, scope: "read")
      assert %{"board" => _} = conn |> get(~p"/api/boards/#{ctx.board.id}") |> json_response(200)
    end

    test "cannot edit a card", ctx do
      conn = with_token(ctx.conn, ctx.user, scope: "read")
      body = conn |> patch(~p"/api/cards/#{ctx.card.id}", %{title: "nope"}) |> json_response(403)

      assert body["error"] =~ "read-only"
      assert Boards.get_card!(ctx.card.id).title == "A card"
    end

    test "cannot create a board — a write that reaches no board at all", ctx do
      conn = with_token(ctx.conn, ctx.user, scope: "read")
      body = conn |> post(~p"/api/boards", %{name: "Sneaky"}) |> json_response(403)

      assert body["error"] =~ "read-only"
      refute Enum.any?(Boards.list_boards(), &(&1.name == "Sneaky"))
    end

    test "cannot delete", ctx do
      conn = with_token(ctx.conn, ctx.user, scope: "read")
      assert conn |> delete(~p"/api/cards/#{ctx.card.id}") |> json_response(403)
      assert Boards.get_card!(ctx.card.id)
    end
  end

  describe "a board-scoped token" do
    setup ctx do
      {:ok, other} = Boards.create_board(%{"name" => "Elsewhere"}, owner_id: ctx.user.id)
      %{other: Boards.get_board!(other.id)}
    end

    test "reads the board it names", ctx do
      conn = with_token(ctx.conn, ctx.user, scope_boards: [ctx.board.id])
      assert conn |> get(~p"/api/boards/#{ctx.board.id}") |> json_response(200)
    end

    test "cannot reach a board outside its list, even though the user owns it", ctx do
      conn = with_token(ctx.conn, ctx.user, scope_boards: [ctx.board.id])
      body = conn |> get(~p"/api/boards/#{ctx.other.id}") |> json_response(403)

      assert body["error"] =~ "scope"
    end

    test "cannot even list a board outside its scope", ctx do
      conn = with_token(ctx.conn, ctx.user, scope_boards: [ctx.board.id])

      names =
        conn
        |> get(~p"/api/boards")
        |> json_response(200)
        |> Map.get("boards")
        |> Enum.map(& &1["name"])

      # Blocking the fetch is not enough: an index that still names every
      # board leaks the shape of the account to a confined token.
      assert "Delivery" in names
      refute "Elsewhere" in names
    end

    test "the guide only describes the boards it can reach", ctx do
      conn = with_token(ctx.conn, ctx.user, scope_boards: [ctx.board.id])
      body = conn |> get(~p"/api/guide") |> response(200)

      assert body =~ "Delivery"
      refute body =~ "Elsewhere"
    end

    test "reaches a sub-board of a board it names", ctx do
      {:ok, template} =
        Boards.create_template(%{
          "name" => "Breakdown #{System.unique_integer([:positive])}",
          "columns" => [%{"name" => "To Do"}, %{"name" => "Done"}]
        })

      {:ok, sub} = Slipdock.Fixtures.sub_board(ctx.card, template)

      conn = with_token(ctx.conn, ctx.user, scope_boards: [ctx.board.id])
      assert conn |> get(~p"/api/boards/#{sub.id}") |> json_response(200)
    end
  end

  describe "narrow/3" do
    test "a nil token narrows nothing — a browser session has no scope" do
      assert Access.narrow(:owner, nil, 1) == {:owner, nil}
    end

    test "read caps an owner at read, and says the scope did it" do
      assert Access.narrow(:owner, %{scope: "read", scope_boards: []}, 1) == {:read, :scope}
    end

    test "read leaves an already-lower level alone" do
      assert Access.narrow(:read, %{scope: "read", scope_boards: []}, 1) == {:read, nil}
      assert Access.narrow(:none, %{scope: "read", scope_boards: []}, 1) == {:none, nil}
    end

    test "a board outside the list is :none whatever the user may do" do
      token = %{scope: "write", scope_boards: [99]}
      assert Access.narrow(:owner, token, 1) == {:none, :scope}
    end

    test "never widens: a scope cannot raise what the user does not have" do
      token = %{scope: "write", scope_boards: []}
      assert Access.narrow(:read, token, 1) == {:read, nil}
      assert Access.narrow(:none, token, 1) == {:none, nil}
    end
  end

  test "a write token still works exactly as before", ctx do
    conn = with_token(ctx.conn, ctx.user, scope: "write")
    assert conn |> patch(~p"/api/cards/#{ctx.card.id}", %{title: "edited"}) |> json_response(200)
    assert Boards.get_card!(ctx.card.id).title == "edited"
  end

  test "an expired token is refused before scope is even considered", ctx do
    conn =
      with_token(ctx.conn, ctx.user,
        scope: "write",
        expires_at: DateTime.utc_now(:second) |> DateTime.add(-1, :day)
      )

    assert conn |> get(~p"/api/boards/#{ctx.board.id}") |> json_response(401)
  end
end
