defmodule SlipdockWeb.HandoffAPITest do
  @moduledoc """
  A card's handoff over HTTP and MCP (W-1804): written and read back both
  ways, shown by `get_card`, cleared, and refused to anyone who may not
  comment on the card or whose token doesn't reach it.
  """
  use SlipdockWeb.ConnCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Access, Accounts, Boards}

  setup %{user: owner} do
    board = board_fixture(%{}, owner: owner)
    card = card_fixture(hd(board.columns), %{"title" => "Half done"})
    commenter = user_fixture("commenter@example.com")
    reader = user_fixture("reader@example.com")
    {:ok, _} = Access.grant(board, reader, "read", owner)
    {:ok, _} = Access.grant(board, commenter, "read", owner)
    {:ok, _} = Access.grant(card, commenter, "comment", owner)

    stranger = user_fixture("stranger@example.com")
    theirs = board_fixture(%{}, owner: stranger)
    secret = card_fixture(hd(theirs.columns), %{"title" => "Their card"})

    %{
      board: board,
      card: card,
      owner: owner,
      commenter: commenter,
      reader: reader,
      secret: secret
    }
  end

  defp as(user), do: user |> conn_as() |> put_req_header("accept", "application/json")

  defp with_token(user, opts) do
    {token, _} = Accounts.create_api_token(user, "limited", opts)

    build_conn()
    |> put_req_header("accept", "application/json")
    |> put_req_header("authorization", "Bearer " <> token)
  end

  describe "POST and GET /api/cards/:id/handoff" do
    test "writes one and reads it back, newest first, with the card showing it", ctx do
      id = ctx.card.id

      assert %{"handoff" => %{"next_step" => "Write the tests", "via" => "api"}} =
               as(ctx.owner)
               |> post("/api/cards/#{id}/handoff", %{next_step: "Write the tests"})
               |> json_response(201)

      assert %{"handoff" => %{"next_step" => "Run CI", "body" => "State: green", "via" => "cli"}} =
               as(ctx.owner)
               |> post("/api/cards/#{id}/handoff", %{
                 next_step: "Run CI",
                 body: "State: green",
                 via: "cli"
               })
               |> json_response(201)

      assert %{"card" => ^id, "handoff" => current, "history" => [newest, oldest]} =
               as(ctx.owner) |> get("/api/cards/#{id}/handoff") |> json_response(200)

      assert current["next_step"] == "Run CI"
      assert current["by"]["email"] == ctx.owner.email
      assert newest["next_step"] == "Run CI"
      assert oldest["next_step"] == "Write the tests"

      assert %{"handoff" => %{"next_step" => "Run CI", "body" => "State: green"}} =
               as(ctx.owner) |> get("/api/cards/#{id}") |> json_response(200) |> Map.get("card")
    end

    test "a card with none has a nil handoff and no history", ctx do
      assert %{"handoff" => nil, "history" => []} =
               as(ctx.owner) |> get("/api/cards/#{ctx.card.id}/handoff") |> json_response(200)

      assert %{"handoff" => nil} =
               as(ctx.owner)
               |> get("/api/cards/#{ctx.card.id}")
               |> json_response(200)
               |> Map.get("card")
    end

    test "a via other than cli is api: a caller can't claim to be a runner", ctx do
      assert %{"handoff" => %{"via" => "api"}} =
               as(ctx.owner)
               |> post("/api/cards/#{ctx.card.id}/handoff", %{next_step: "Go", via: "runner"})
               |> json_response(201)
    end

    test "no next step is a 422 that says what to do", ctx do
      assert %{"details" => %{"next_step" => [message]}} =
               as(ctx.owner)
               |> post("/api/cards/#{ctx.card.id}/handoff", %{body: "only a note"})
               |> json_response(422)

      assert message =~ "say the one next step"
      assert Boards.handoff_history(ctx.card) == []
    end

    test "clear: true clears it, and the history shows the clear", ctx do
      {:ok, _} = Boards.leave_handoff(ctx.card, ctx.owner, %{next_step: "Old", via: "ui"})

      assert %{"handoff" => %{"cleared" => true, "next_step" => nil}} =
               as(ctx.owner)
               |> post("/api/cards/#{ctx.card.id}/handoff", %{clear: true})
               |> json_response(201)

      assert %{"handoff" => nil, "history" => [%{"cleared" => true}, %{"next_step" => "Old"}]} =
               as(ctx.owner) |> get("/api/cards/#{ctx.card.id}/handoff") |> json_response(200)

      assert %{"handoff" => nil} =
               as(ctx.owner)
               |> get("/api/cards/#{ctx.card.id}")
               |> json_response(200)
               |> Map.get("card")
    end

    test "someone who may only comment on the card may write one", ctx do
      assert %{"handoff" => %{"next_step" => "Over to you"}} =
               as(ctx.commenter)
               |> post("/api/cards/#{ctx.card.id}/handoff", %{next_step: "Over to you"})
               |> json_response(201)
    end

    test "a reader may read it but not write one", ctx do
      {:ok, _} = Boards.leave_handoff(ctx.card, ctx.owner, %{next_step: "Mine", via: "ui"})

      assert %{"handoff" => %{"next_step" => "Mine"}} =
               as(ctx.reader) |> get("/api/cards/#{ctx.card.id}/handoff") |> json_response(200)

      assert as(ctx.reader)
             |> post("/api/cards/#{ctx.card.id}/handoff", %{next_step: "Theirs"})
             |> json_response(403)

      assert [%{next_step: "Mine"}] = Boards.handoff_history(ctx.card)
    end

    test "a stranger's card is neither read nor written", ctx do
      conn = as(ctx.owner)
      assert conn |> get("/api/cards/#{ctx.secret.id}/handoff") |> json_response(403)

      assert as(ctx.owner)
             |> post("/api/cards/#{ctx.secret.id}/handoff", %{next_step: "Sneak"})
             |> json_response(403)

      assert as(ctx.owner) |> get("/api/cards/999999999/handoff") |> json_response(404)
      assert Boards.handoff_history(ctx.secret) == []
    end

    test "a read-only token, or one scoped to another board, can't write one", ctx do
      other = board_fixture(%{}, owner: ctx.owner)

      for conn <- [
            with_token(ctx.owner, scope: "read"),
            with_token(ctx.owner, scope: "write", scope_boards: [other.id])
          ] do
        assert conn
               |> post("/api/cards/#{ctx.card.id}/handoff", %{next_step: "Off scope"})
               |> json_response(403)
      end

      assert Boards.handoff_history(ctx.card) == []
    end
  end

  describe "MCP" do
    defp call(conn, tool, args) do
      conn
      |> put_req_header("content-type", "application/json")
      |> post(
        "/mcp",
        Jason.encode!(%{
          jsonrpc: "2.0",
          id: 1,
          method: "tools/call",
          params: %{name: tool, arguments: args}
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
      assert result["isError"] == true
      [%{"text" => text}] = result["content"]
      text
    end

    test "leave_handoff writes it as from MCP, and get_card shows it", ctx do
      id = ctx.card.id

      assert %{"handoff" => %{"next_step" => "Fix the seed", "via" => "mcp"}} =
               as(ctx.owner)
               |> call("leave_handoff", %{
                 card: id,
                 next_step: "Fix the seed",
                 body: "Gotchas: 42"
               })
               |> ok!()

      assert %{"handoff" => %{"next_step" => "Fix the seed", "body" => "Gotchas: 42"}} =
               as(ctx.owner) |> call("get_card", %{card: id}) |> ok!()
    end

    test "clear takes the string a command line sends", ctx do
      {:ok, _} = Boards.leave_handoff(ctx.card, ctx.owner, %{next_step: "Old", via: "ui"})

      assert %{"handoff" => %{"cleared" => true}} =
               as(ctx.owner)
               |> call("leave_handoff", %{card: ctx.card.id, clear: "true"})
               |> ok!()

      assert %{"handoff" => nil} =
               as(ctx.owner) |> call("get_card", %{card: ctx.card.id}) |> ok!()
    end

    test "no next step is refused with what to do", ctx do
      text = as(ctx.owner) |> call("leave_handoff", %{card: ctx.card.id}) |> error!()
      assert text =~ "next_step can't be blank: say the one next step"
    end

    test "a commenter may, a reader, a read-only token and a stranger may not", ctx do
      assert as(ctx.commenter)
             |> call("leave_handoff", %{card: ctx.card.id, next_step: "Mine"})
             |> ok!()

      assert as(ctx.reader)
             |> call("leave_handoff", %{card: ctx.card.id, next_step: "No"})
             |> error!()

      assert with_token(ctx.owner, scope: "read")
             |> call("leave_handoff", %{card: ctx.card.id, next_step: "No"})
             |> error!()

      assert as(ctx.owner)
             |> call("leave_handoff", %{card: ctx.secret.id, next_step: "No"})
             |> error!() =~ "you don't comment on this card"

      assert [%{next_step: "Mine"}] = Boards.handoff_history(ctx.card)
    end

    test "tools/list has it as a write, and get_card says to read the handoff first", ctx do
      tools =
        as(ctx.owner)
        |> put_req_header("content-type", "application/json")
        |> post("/mcp", Jason.encode!(%{jsonrpc: "2.0", id: 1, method: "tools/list"}))
        |> json_response(200)
        |> get_in(["result", "tools"])
        |> Map.new(&{&1["name"], &1})

      assert tools["leave_handoff"]["annotations"]["readOnlyHint"] == false
      assert tools["get_card"]["description"] =~ "handoff (where it was left: read it first"
    end
  end
end
