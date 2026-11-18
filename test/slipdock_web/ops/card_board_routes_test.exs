defmodule SlipdockWeb.Ops.CardBoardRoutesTest do
  @moduledoc """
  The four routes the composite MCP tools drive, made from definitions
  (#3361): `PATCH /api/cards/:id` (`edit_card`), `POST
  /api/boards/:board/cards` (`add_card`), `PATCH /api/boards/:board`
  (`set_board`) and `POST /api/boards` (`new_board`). Each takes what the
  route took before it, a null clearing a field as it always did; and what
  the definitions settled between REST and MCP holds on REST.
  """
  use SlipdockWeb.ConnCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Accounts, Boards, Repo}
  alias Slipdock.Boards.{Board, Card}
  alias SlipdockWeb.API.CardWrites
  alias SlipdockWeb.Ops

  setup %{user: user} do
    board = board_fixture(%{"name" => "Routes", "code" => "rts3361"}, owner: user)
    [todo | _] = board.columns
    %{board: board, todo: todo, card: card_fixture(todo, %{"title" => "Ship it"})}
  end

  defp board_by_code(code), do: Repo.get_by(Board, code: code)

  defp token_conn(user, opts) do
    {token, _} = Accounts.create_api_token(user, "agent", opts)

    build_conn()
    |> put_req_header("authorization", "Bearer " <> token)
    |> put_req_header("accept", "application/json")
  end

  describe "the definitions take every key the route reads" do
    test "edit_card: every card field, and the update's own keys" do
      names = Enum.map(Ops.EditCard.definition().params, & &1.name)
      assert CardWrites.card_fields() -- names == []

      assert ~w(changed_lines changed_files add_flags remove_flags tags add_tags remove_tags
                assignee assignees add_assignees remove_assignees column fields) -- names == []
    end

    test "add_card: every key a new card takes, and no other" do
      names = for p <- Ops.AddCard.definition().params, !p[:in_path], do: p.name
      assert Enum.sort(names) == Enum.sort(CardWrites.create_keys())
    end
  end

  describe "PATCH /api/cards/:id (edit_card)" do
    test "changes what is sent, and a null clears a field", ctx do
      ctx.conn
      |> patch("/api/cards/#{ctx.card.id}", %{title: "Shipped", due_date: "2026-12-01"})
      |> json_response(200)

      card = Boards.Cards.get_card!(ctx.card.id)
      assert card.title == "Shipped"
      assert card.due_date == ~D[2026-12-01]

      body =
        ctx.conn
        |> put_req_header("content-type", "application/json")
        |> patch("/api/cards/#{ctx.card.id}", Jason.encode!(%{due_date: nil}))
        |> json_response(200)

      assert body["card"]["title"] == "Shipped"
      assert Boards.Cards.get_card!(ctx.card.id).due_date == nil
    end

    test "a card that isn't there is a 404; one the caller can't write a 403", ctx do
      assert ctx.conn |> patch("/api/cards/999999999", %{title: "x"}) |> json_response(404)

      other = user_fixture("reader3361@example.com")
      share_fixture(ctx.board, other, "read")

      assert other
             |> token_conn([])
             |> patch("/api/cards/#{ctx.card.id}", %{title: "Mine now"})
             |> json_response(403)

      assert Boards.Cards.get_card!(ctx.card.id).title == "Ship it"
    end
  end

  describe "POST /api/boards/:board/cards (add_card)" do
    test "makes the card (201) in the board's first list", ctx do
      body =
        ctx.conn
        |> post("/api/boards/#{ctx.board.code}/cards", %{title: "New", tags: []})
        |> json_response(201)

      assert body["card"]["title"] == "New"
      assert body["card"]["column_id"] == ctx.todo.id
    end

    test "refuses a field a new card doesn't have, naming it, and makes nothing", ctx do
      %{"error" => error} =
        ctx.conn
        |> post("/api/boards/#{ctx.board.code}/cards", %{title: "New", archved: true})
        |> json_response(422)

      assert error =~ ~s(a new card has no field "archved")
      refute Repo.get_by(Card, title: "New", board_id: ctx.board.id)
    end
  end

  describe "PATCH /api/boards/:board (set_board)" do
    test "the owner changes a setting", ctx do
      body =
        ctx.conn
        |> patch("/api/boards/#{ctx.board.code}", %{description: "Where it ships"})
        |> json_response(200)

      assert body["board"]["id"] == ctx.board.id
      assert Boards.get_board!(ctx.board.id).description == "Where it ships"
    end

    test "a writer who isn't the owner is refused, and nothing changes", ctx do
      other = user_fixture("reader3361@example.com")
      share_fixture(ctx.board, other, "write")

      assert other
             |> token_conn([])
             |> patch("/api/boards/#{ctx.board.code}", %{name: "Taken"})
             |> json_response(403)

      assert Boards.get_board!(ctx.board.id).name == "Routes"
    end
  end

  describe "POST /api/boards (new_board)" do
    test "lists names the board's own lists, and columns is still taken", ctx do
      for {key, code} <- [{"lists", "nb3361a"}, {"columns", "nb3361b"}] do
        body =
          ctx.conn
          |> post("/api/boards", %{"name" => "Hiring", "code" => code, key => ["Applied", "Done"]})
          |> json_response(201)

        board = Boards.get_board!(body["board"]["id"])
        assert Enum.map(board.columns, & &1.name) == ["Applied", "Done"], key
      end
    end

    test "an unknown template is a 404 and makes no board", ctx do
      assert ctx.conn
             |> post("/api/boards", %{name: "Nope", code: "nb3361c", template: "No such"})
             |> json_response(404)

      refute board_by_code("nb3361c")
    end

    test "a token confined to some boards is refused, as MCP refuses it", ctx do
      %{"error" => error} =
        ctx.user
        |> token_conn(scope_boards: [ctx.board.id])
        |> post("/api/boards", %{name: "Escape", code: "nb3361d"})
        |> json_response(403)

      assert error =~ "scope doesn't allow it to create boards"

      assert {true, text} =
               call_mcp_tool(
                 token_conn(ctx.user, scope_boards: [ctx.board.id]),
                 "create_board",
                 %{name: "Escape", code: "nb3361e"}
               )

      assert text =~ "scope doesn't allow it to create boards"
      refute board_by_code("nb3361d")
      refute board_by_code("nb3361e")
    end

    test "a token for the whole account still makes one", ctx do
      assert ctx.user
             |> token_conn([])
             |> post("/api/boards", %{name: "Whole", code: "nb3361f"})
             |> json_response(201)
    end
  end
end
