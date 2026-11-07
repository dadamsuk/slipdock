defmodule SlipdockWeb.WaitRoutesWebTest do
  @moduledoc """
  Wait routes at every door (#1949): board settings' *Who gets asked* rows
  (saved, and a refusal said in a callout), `PATCH /api/boards/:board`
  `wait_routes` and the board's JSON, MCP `update_board` `wait_routes`, a
  wait opened with `question` over REST and MCP, and the kind shown on the
  wait in the card panel, `GET /api/cards/:id` and `get_card`.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Access, Accounts, Boards, Repo}
  alias Slipdock.Boards.{Board, Wait}

  setup %{user: owner} do
    board = board_fixture(%{"name" => "Routed"}, owner: owner)
    pm = user_fixture("routes-web-pm@example.com")
    rel = user_fixture("routes-web-rel@example.com")
    stranger = user_fixture("routes-web-x@example.com")
    for u <- [pm, rel], do: {:ok, _} = Access.grant(board, u, "write", owner)
    card = card_fixture(hd(board.columns), %{"title" => "Asks"})
    %{board: board, pm: pm, rel: rel, stranger: stranger, card: card, owner: owner}
  end

  defp json_conn(conn), do: put_req_header(conn, "accept", "application/json")

  # An agent's token, as a runner's would be.
  defp agent_conn(user) do
    {token, _} = Accounts.create_api_token(user, "agent")

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

  defp routes(board), do: Repo.get!(Board, board.id).wait_routes

  describe "board settings" do
    test "the owner sets each kind's people, and blanks one to take it off", ctx do
      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/settings")
      assert has_element?(view, "#board-wait-routes", "Who gets asked")

      for kind <- Slipdock.WaitRoutes.kinds(),
          do: assert(has_element?(view, "#board-route-#{kind}"))

      view
      |> form("#board-form",
        board: %{
          "wait_routes" => %{
            "product" => "#{ctx.pm.email}, #{ctx.rel.email}",
            "release" => ctx.rel.email
          }
        }
      )
      |> render_submit()

      assert routes(ctx.board) == %{
               "product" => [ctx.pm.id, ctx.rel.id],
               "release" => [ctx.rel.id]
             }

      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/settings")

      assert has_element?(
               view,
               ~s(#board-route-product[value="#{ctx.pm.email}, #{ctx.rel.email}"])
             )

      view
      |> form("#board-form", board: %{"wait_routes" => %{"product" => ""}})
      |> render_submit()

      assert routes(ctx.board) == %{"release" => [ctx.rel.id]}
    end

    test "someone not on the board is refused in a callout, and nothing is saved", ctx do
      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/settings")

      html =
        view
        |> form("#board-form", board: %{"wait_routes" => %{"ux" => ctx.stranger.email}})
        |> render_submit()

      assert html =~ "isn&#39;t a user of this board"
      assert has_element?(view, "#board-wait-routes-error")
      assert routes(ctx.board) == %{}
    end

    test "a writer who isn't the owner doesn't see the rows", ctx do
      {:ok, view, _} = live(conn_as(ctx.pm), ~p"/boards/#{ctx.board}/settings")
      refute has_element?(view, "#board-wait-routes")
    end
  end

  describe "REST" do
    test "PATCH sets wait_routes; the board's JSON shows them as people", ctx do
      body =
        ctx.conn
        |> json_conn()
        |> patch(~p"/api/boards/#{ctx.board.code}", %{
          "wait_routes" => %{"product" => [ctx.pm.email]}
        })
        |> json_response(200)

      assert [%{"id" => id, "email" => email}] = body["board"]["wait_routes"]["product"]
      assert {id, email} == {ctx.pm.id, ctx.pm.email}
      assert body["board"]["wait_routes"]["ux"] == []
      assert routes(ctx.board) == %{"product" => [ctx.pm.id]}
    end

    test "PATCH refuses a stranger and an unknown kind with a 422", ctx do
      for bad <- [%{"ux" => [ctx.stranger.email]}, %{"finance" => [ctx.pm.email]}] do
        assert %{"error" => "wait_routes: " <> _} =
                 ctx.conn
                 |> json_conn()
                 |> patch(~p"/api/boards/#{ctx.board.code}", %{"wait_routes" => bad})
                 |> json_response(422)
      end

      assert routes(ctx.board) == %{}
    end

    test "only the owner may PATCH them", ctx do
      assert ctx.pm
             |> conn_as()
             |> json_conn()
             |> patch(~p"/api/boards/#{ctx.board.code}", %{
               "wait_routes" => %{"ux" => [ctx.pm.email]}
             })
             |> json_response(403)

      assert routes(ctx.board) == %{}
    end

    test "a wait opened with question goes by the route, and shows its kind", ctx do
      {:ok, _} = Slipdock.WaitRoutes.set(ctx.board, %{"product" => [ctx.pm.email]})

      body =
        ctx.owner
        |> agent_conn()
        |> post(
          ~p"/api/cards/#{ctx.card.id}/wait",
          Jason.encode!(%{"needs" => "Tier?", "question" => "product"})
        )
        |> json_response(201)

      assert body["wait"]["question"] == "product"
      assert body["wait"]["on"]["id"] == ctx.pm.id
      assert body["wait"]["kind"] == "agent"

      card = ctx.conn |> json_conn() |> get(~p"/api/cards/#{ctx.card.id}") |> json_response(200)
      assert card["card"]["wait"]["question"] == "product"
    end

    test "an unknown question kind is a 422", ctx do
      assert %{"error" => _} =
               ctx.owner
               |> agent_conn()
               |> post(
                 ~p"/api/cards/#{ctx.card.id}/wait",
                 Jason.encode!(%{"needs" => "?", "question" => "finance"})
               )
               |> json_response(422)

      assert Boards.current_wait(ctx.card) == nil
    end
  end

  describe "MCP" do
    test "update_board sets wait_routes and answers with them; a stranger is refused", ctx do
      conn = agent_conn(ctx.owner)

      result =
        mcp(conn, "update_board", %{
          board: ctx.board.code,
          wait_routes: %{release: [ctx.rel.email]}
        })

      assert result["isError"] == false
      assert [%{"id" => id}] = result["structuredContent"]["wait_routes"]["release"]
      assert id == ctx.rel.id
      assert routes(ctx.board) == %{"release" => [ctx.rel.id]}

      bad =
        mcp(conn, "update_board", %{
          board: ctx.board.code,
          wait_routes: %{ux: [ctx.stranger.email]}
        })

      assert bad["isError"] == true
      assert [%{"text" => text}] = bad["content"]
      assert text =~ "isn't a user of this board"
    end

    test "update_card's wait takes question, and get_card shows it", ctx do
      {:ok, _} = Slipdock.WaitRoutes.set(ctx.board, %{"ux" => [ctx.pm.email]})
      conn = agent_conn(ctx.owner)

      result =
        mcp(conn, "update_card", %{
          card: ctx.card.id,
          wait: %{needs: "Which layout?", question: "ux"}
        })

      assert result["isError"] == false, inspect(result)
      wait = Repo.get_by!(Wait, card_id: ctx.card.id)
      assert {wait.question, wait.on_user_id} == {"ux", ctx.pm.id}

      got = mcp(conn, "get_card", %{card: ctx.card.id})
      assert got["structuredContent"]["wait"]["question"] == "ux"
    end
  end

  test "the card panel shows the wait's kind", ctx do
    {:ok, _} = Slipdock.WaitRoutes.set(ctx.board, %{"security" => [ctx.pm.email]})

    {:ok, _} =
      Boards.open_wait(ctx.card, Slipdock.Actor.web(ctx.owner), %{
        "needs" => "Is this safe?",
        "question" => "security"
      })

    {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/cards/#{ctx.card.id}")
    assert has_element?(view, "#wait-question", "security")

    assert has_element?(
             view,
             "#card-wait",
             "Waiting on #{Slipdock.Accounts.User.display_name(ctx.pm)}"
           )
  end
end
