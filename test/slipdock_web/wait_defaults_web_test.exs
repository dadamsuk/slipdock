defmodule SlipdockWeb.WaitDefaultsWebTest do
  @moduledoc """
  A moot wait clears itself (#2096), at every door: `wait_default_after` on
  the Agentic Building page, `PATCH /api/boards/:board`, the board's JSON
  and MCP `update_board`; a wait's proposed choice (`default`) over REST
  and MCP, in the wait's JSON and marked on the card panel; and a moot
  wait withdrawn by another agent, refused without a `reason` and allowed
  with one, over REST and MCP (`wait: null` with `wait_reason`).
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Accounts, Boards, Repo}
  alias Slipdock.Boards.{Board, Wait}

  setup %{user: owner} do
    board = board_fixture(%{"name" => "Defaulted"}, owner: owner)
    card = card_fixture(hd(board.columns), %{"title" => "Copies"})
    %{board: board, card: card, owner: owner}
  end

  # An agent's token, under its own label: two labels are two agents.
  defp agent_conn(user, label) do
    {token, _} = Accounts.create_api_token(user, label)

    build_conn()
    |> put_req_header("accept", "application/json")
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer " <> token)
  end

  defp mcp(conn, tool, args) do
    conn
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

  defp setting(board), do: Repo.get!(Board, board.id).wait_default_after

  defp open_approval(conn, card) do
    conn
    |> post(~p"/api/cards/#{card.id}/wait", %{
      "needs" => "Read bar 2 as the one copy?",
      "choices" => ["Yes", "No"],
      "default" => 1
    })
    |> json_response(201)
  end

  describe "the board setting" do
    test "PATCH takes 4h and the JSON reads it back; off clears it; nonsense is a 422", ctx do
      conn = agent_conn(ctx.owner, "builder")

      json =
        conn
        |> patch(~p"/api/boards/#{ctx.board.id}", %{"wait_default_after" => "4h"})
        |> json_response(200)

      assert json["board"]["wait_default_after"] == "4h"
      assert setting(ctx.board) == 240

      json = conn |> get(~p"/api/boards/#{ctx.board.id}") |> json_response(200)
      assert json["board"]["wait_default_after"] == "4h"

      conn
      |> patch(~p"/api/boards/#{ctx.board.id}", %{"wait_default_after" => "off"})
      |> json_response(200)

      assert setting(ctx.board) == nil

      body =
        conn
        |> patch(~p"/api/boards/#{ctx.board.id}", %{"wait_default_after" => "soon"})
        |> json_response(422)

      assert inspect(body) =~ "must be a time like 4h, 90m or 2d"
    end

    test "MCP update_board sets it", ctx do
      result =
        mcp(agent_conn(ctx.owner, "builder"), "update_board", %{
          "board" => to_string(ctx.board.id),
          "wait_default_after" => "90m"
        })

      assert result["isError"] == false, inspect(result)
      assert setting(ctx.board) == 90
    end

    test "the Agentic Building page shows it, saves it and says what is wrong", ctx do
      {:ok, view, html} = live(ctx.conn, agentic_path(ctx.board))
      assert html =~ "An approval&#39;s proposal stands after"
      assert has_element?(view, "#board-wait-default-after")

      view
      |> form("#agentic-form", board: %{"wait_default_after" => "2d"})
      |> render_submit()

      assert setting(ctx.board) == 2880

      {:ok, view, _} = live(ctx.conn, agentic_path(ctx.board))
      assert has_element?(view, "#board-wait-default-after[value='2d']")

      html =
        view
        |> form("#agentic-form", board: %{"wait_default_after" => "whenever"})
        |> render_submit()

      assert html =~ "must be a time like 4h, 90m or 2d"
      assert setting(ctx.board) == 2880
    end
  end

  describe "a proposed choice" do
    test "REST keeps it and the wait's JSON carries it; out of range is a 422", ctx do
      conn = agent_conn(ctx.owner, "builder")
      json = open_approval(conn, ctx.card)
      assert json["wait"]["default_choice"] == 1

      json = conn |> get(~p"/api/cards/#{ctx.card.id}") |> json_response(200)
      assert json["card"]["wait"]["default_choice"] == 1

      other = card_fixture(hd(ctx.board.columns), %{"title" => "Other"})

      body =
        conn
        |> post(~p"/api/cards/#{other.id}/wait", %{
          "needs" => "Which?",
          "choices" => ["a"],
          "default" => 4
        })
        |> json_response(422)

      assert inspect(body) =~ "must be a choice's number"
    end

    test "MCP update_card wait takes default", ctx do
      result =
        mcp(agent_conn(ctx.owner, "builder"), "update_card", %{
          "card" => ctx.card.id,
          "wait" => %{"needs" => "Ship it?", "choices" => ["Yes", "No"], "default" => 2}
        })

      assert result["isError"] == false, inspect(result)
      assert Boards.Waits.current_wait(ctx.card).default_choice == 2
    end

    test "the card panel marks the proposed choice", ctx do
      open_approval(agent_conn(ctx.owner, "builder"), ctx.card)

      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board.id}/cards/#{ctx.card.id}")
      assert has_element?(view, "#wait-choice-1", "(proposed)")
      refute has_element?(view, "#wait-choice-2", "(proposed)")
    end
  end

  describe "withdrawing another agent's wait" do
    test "REST: refused without a reason, allowed with one, which the card shows", ctx do
      open_approval(agent_conn(ctx.owner, "builder"), ctx.card)
      other = agent_conn(ctx.owner, "verifier")

      body = other |> delete(~p"/api/cards/#{ctx.card.id}/wait") |> json_response(422)
      assert inspect(body) =~ "says why: give a reason"
      assert Boards.Waits.current_wait(ctx.card)

      json =
        other
        |> delete(~p"/api/cards/#{ctx.card.id}/wait?reason=Moot%3A+W-2514+settled+it")
        |> json_response(200)

      assert json["wait"]["close_reason"] == "withdrawn"

      assert Enum.any?(
               Boards.Cards.get_card!(ctx.card.id).comments,
               &(&1.body =~
                   "withdrew the wait “Read bar 2 as the one copy?”: Moot: W-2514 settled it")
             )
    end

    test "REST: the agent that opened it needs none", ctx do
      conn = agent_conn(ctx.owner, "builder")
      open_approval(conn, ctx.card)
      conn |> delete(~p"/api/cards/#{ctx.card.id}/wait") |> json_response(200)
    end

    test "MCP: wait null is refused without wait_reason, and withdraws with it", ctx do
      open_approval(agent_conn(ctx.owner, "builder"), ctx.card)
      other = agent_conn(ctx.owner, "verifier")

      result = mcp(other, "update_card", %{"card" => ctx.card.id, "wait" => nil})
      assert result["isError"] == true
      assert inspect(result) =~ "give a reason"

      result =
        mcp(other, "update_card", %{
          "card" => ctx.card.id,
          "wait" => nil,
          "wait_reason" => "The bar was edited since"
        })

      assert result["isError"] == false, inspect(result)
      assert Boards.Waits.current_wait(ctx.card) == nil
      assert Repo.get_by!(Wait, card_id: ctx.card.id).close_reason == "withdrawn"
    end
  end
end
