defmodule SlipdockWeb.ShipViaWebTest do
  @moduledoc """
  Ship by PR 1 (#1654) at the doors: `ship_via` over REST and MCP, its
  refusal without verification, settings, the board's JSON and list_boards,
  complete_card's `pr`, the pull request linked in the card panel, and the
  guide saying so only on a board that ships by pull request.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Accounts, Boards, Repo}
  alias Slipdock.Boards.Card

  @pr "https://github.com/acme/app/pull/7"

  setup %{user: user} do
    board = board_fixture(%{"name" => "Ships", "code" => unique_code()}, owner: user)
    [_backlog, _todo, doing, _done] = board.columns
    card = card_fixture(doing, %{"title" => "Work"})
    {token, _} = Accounts.create_api_token(user, "bot")

    agent =
      build_conn()
      |> put_req_header("accept", "application/json")
      |> put_req_header("authorization", "Bearer " <> token)

    %{board: board, doing: doing, card: card, agent: agent}
  end

  defp mcp(conn, tool, args) do
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

  test "PATCH /api/boards: push by default, pull_request refused alone, taken with verify_work",
       ctx do
    board = ctx.agent |> get(~p"/api/boards/#{ctx.board.id}") |> json_response(200)
    assert board["board"]["ship_via"] == "push"

    body =
      ctx.agent
      |> patch(~p"/api/boards/#{ctx.board.id}", %{"ship_via" => "pull_request"})
      |> json_response(422)

    assert Map.has_key?(body["details"], "ship_via")

    resp =
      ctx.agent
      |> patch(~p"/api/boards/#{ctx.board.id}", %{
        "verify_work" => true,
        "ship_via" => "pull_request"
      })
      |> json_response(200)

    assert resp["board"]["ship_via"] == "pull_request"
  end

  test "MCP update_board sets it, and list_boards reports it", ctx do
    result =
      mcp(ctx.agent, "update_board", %{
        board: ctx.board.code,
        verify_work: true,
        ship_via: "pull_request"
      })

    assert result["isError"] == false
    assert Boards.get_board!(ctx.board.id).ship_via == "pull_request"

    result = mcp(ctx.agent, "list_boards", %{})
    assert [%{"text" => text}] = result["content"]

    assert Jason.decode!(text)["boards"] |> hd() |> get_in(["verified_work", "ship_via"]) ==
             "pull_request"

    result = mcp(ctx.agent, "update_board", %{board: ctx.board.code, verify_work: false})
    assert result["isError"] == false
    assert Boards.get_board!(ctx.board.id).ship_via == "push"
  end

  test "complete_card takes pr; a pull_request board asking for evidence refuses without it",
       ctx do
    {:ok, _} =
      Boards.update_board(ctx.board, %{
        "verify_work" => true,
        "evidence_required" => true,
        "ship_via" => "pull_request"
      })

    result = mcp(ctx.agent, "complete_card", %{card: ctx.card.id, evidence: "mix test"})
    assert result["isError"] == true
    assert [%{"text" => text}] = result["content"]
    assert text =~ "evidence_pr"

    result = mcp(ctx.agent, "complete_card", %{card: ctx.card.id, evidence: "x", pr: @pr})
    assert result["isError"] == false
    card = Repo.get!(Card, ctx.card.id)
    assert card.evidence_pr == @pr and card.verify_state == "pending"

    json = ctx.agent |> get(~p"/api/cards/#{ctx.card.id}") |> json_response(200)
    assert json["card"]["evidence_pr"] == @pr
  end

  test "settings show the choice with verification on, and save it", ctx do
    {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/settings")
    refute has_element?(view, "#board-ship-via")

    {:ok, _} = Boards.update_board(ctx.board, %{"verify_work" => true})
    {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/settings")
    assert has_element?(view, "#board-ship-via option[value=pull_request]")

    view
    |> form("#board-form", board: %{"verify_work" => "true", "ship_via" => "pull_request"})
    |> render_submit()

    assert Boards.get_board!(ctx.board.id).ship_via == "pull_request"
  end

  test "the card panel links the pull request", ctx do
    {:ok, _} = Boards.update_card(ctx.card, %{"evidence_pr" => @pr})
    {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/cards/#{ctx.card}")
    assert has_element?(view, ~s(#card-evidence-pr a[href="#{@pr}"]))
  end

  test "the guide says how to ship only when a board ships by pull request", ctx do
    {:ok, board} = Boards.update_board(ctx.board, %{"verify_work" => true})
    guide = ctx.agent |> get(~p"/api/guide") |> response(200)
    refute guide =~ "Shipping by pull request"
    refute guide =~ "ships by pull request"

    {:ok, _} = Boards.update_board(board, %{"ship_via" => "pull_request"})
    guide = ctx.agent |> get(~p"/api/guide") |> response(200)
    assert guide =~ "**Shipping by pull request**"
    assert guide =~ "ships by pull request: push `card-<id>`"
  end

  describe "the card says how it ships (#1655)" do
    test "GET /api/cards and MCP get_card carry shipping on a pull_request board only", ctx do
      json = ctx.agent |> get(~p"/api/cards/#{ctx.card.id}") |> json_response(200)
      refute Map.has_key?(json["card"], "shipping")

      {:ok, _} =
        Boards.update_board(ctx.board, %{"verify_work" => true, "ship_via" => "pull_request"})

      json = ctx.agent |> get(~p"/api/cards/#{ctx.card.id}") |> json_response(200)
      branch = "card-#{ctx.card.id}"

      assert %{"via" => "pull_request", "branch" => ^branch, "instructions" => text} =
               json["card"]["shipping"]

      assert text =~ "never push the default branch"

      result = mcp(ctx.agent, "get_card", %{card: ctx.card.id})
      assert [%{"text" => text}] = result["content"]
      assert Jason.decode!(text)["shipping"]["branch"] == branch
    end

    test "a claimed job's prompt over MCP claim_job says it too", ctx do
      {:ok, _} =
        Boards.update_board(ctx.board, %{"verify_work" => true, "ship_via" => "pull_request"})

      {:ok, _job} =
        Slipdock.Runners.queue(ctx.card, %{pool: "dev", kind: "claude", prompt: "Go."})

      result = mcp(ctx.agent, "claim_job", %{board: ctx.board.code, pool: "dev"})
      assert result["isError"] == false
      assert [%{"text" => text}] = result["content"]
      assert text =~ "This board ships by pull request"
      assert text =~ "card-#{ctx.card.id}"
    end
  end
end
