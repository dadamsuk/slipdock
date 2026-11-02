defmodule SlipdockWeb.VerifiedVerifyWebTest do
  @moduledoc """
  Verified work 3 (#1633) at the doors: the switch over the API, an agent's
  complete_card submitting instead of closing, POST /api/cards/:id/verify and
  MCP's verify_card refusing the submitter and taking a second agent's
  decision, the card panel's Accept and Reject, and the guide.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Accounts, Boards, Repo}
  alias Slipdock.Boards.Card

  setup %{user: user} do
    board = board_fixture(%{"name" => "Verify", "code" => unique_code()}, owner: user)
    [_backlog, _todo, doing, done] = board.columns
    card = card_fixture(doing, %{"title" => "Work"})

    %{
      board: board,
      doing: doing,
      done: done,
      card: card,
      builder: agent(user, "builder"),
      checker: agent(user, "checker")
    }
  end

  defp agent(user, label) do
    {token, _} = Accounts.create_api_token(user, label)

    build_conn()
    |> put_req_header("accept", "application/json")
    |> put_req_header("authorization", "Bearer " <> token)
  end

  defp on(ctx), do: Boards.update_board(ctx.board, %{"verify_work" => true})

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

  test "the switch is off by default and PATCH /api/boards turns it on", ctx do
    assert (ctx.builder
            |> get(~p"/api/boards/#{ctx.board.id}")
            |> json_response(200))["board"][
             "verify_work"
           ] == false

    resp =
      ctx.builder
      |> patch(~p"/api/boards/#{ctx.board.id}", %{"verify_work" => true})
      |> json_response(200)

    assert resp["board"]["verify_work"] == true
  end

  test "on: complete_card submits, and the card waits in its list", ctx do
    {:ok, _} = on(ctx)
    result = mcp(ctx.builder, "complete_card", %{card: ctx.card.id})
    assert result["isError"] == false
    assert result["structuredContent"]["note"] =~ "submitted for verification"

    card = Repo.get!(Card, ctx.card.id)
    refute card.completed
    assert card.column_id == ctx.doing.id

    json = ctx.builder |> get(~p"/api/cards/#{ctx.card.id}") |> json_response(200)
    assert json["card"]["verify_state"] == "pending"
    assert json["card"]["verify_submitter"]["agent"] == "builder"
  end

  test "on: the submitter is refused over the API; a second agent accepts", ctx do
    {:ok, _} = on(ctx)

    ctx.builder
    |> patch(~p"/api/cards/#{ctx.card.id}", %{"completed" => true})
    |> json_response(200)

    body =
      ctx.builder
      |> post(~p"/api/cards/#{ctx.card.id}/verify", %{"decision" => "accept"})
      |> json_response(403)

    assert body["error"] =~ "you submitted"

    json =
      ctx.checker
      |> post(~p"/api/cards/#{ctx.card.id}/verify", %{"decision" => "accept"})
      |> json_response(200)

    assert json["card"]["completed"]
    assert json["card"]["verify_state"] == "accepted"
    assert Repo.get!(Card, ctx.card.id).column_id == ctx.done.id
  end

  test "on: a card that isn't pending is a 409, a rejection without a reason a 422", ctx do
    {:ok, _} = on(ctx)

    ctx.checker
    |> post(~p"/api/cards/#{ctx.card.id}/verify", %{"decision" => "accept"})
    |> json_response(409)

    ctx.builder
    |> patch(~p"/api/cards/#{ctx.card.id}", %{"completed" => true})
    |> json_response(200)

    ctx.checker
    |> post(~p"/api/cards/#{ctx.card.id}/verify", %{"decision" => "reject"})
    |> json_response(422)
  end

  test "on: MCP's verify_card rejects with the reason, and refuses the submitter", ctx do
    {:ok, _} = on(ctx)
    mcp(ctx.builder, "complete_card", %{card: ctx.card.id})

    result =
      mcp(ctx.builder, "verify_card", %{card: ctx.card.id, decision: "reject", reason: "No"})

    assert result["isError"] == true

    result =
      mcp(ctx.checker, "verify_card", %{
        card: ctx.card.id,
        decision: "reject",
        reason: "Fails on empty"
      })

    assert result["isError"] == false
    card = Repo.get!(Card, ctx.card.id)
    assert card.verify_state == "rejected"
    assert card.verify_note == "Fails on empty"
  end

  test "the card panel offers Accept and Reject on a pending card, and a person decides", ctx do
    {:ok, _} = on(ctx)
    mcp(ctx.builder, "complete_card", %{card: ctx.card.id})

    {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/cards/#{ctx.card}")
    assert has_element?(view, "#card-verify", "Awaiting verification")
    assert has_element?(view, "#card-verify", "agent “builder”")

    view
    |> element("#verify-reject")
    |> render_submit(%{"decision" => "reject", "reason" => "Not yet"})

    assert Repo.get!(Card, ctx.card.id).verify_state == "rejected"
    assert has_element?(view, "#card-verify", "Rejected")
    assert has_element?(view, "#card-verify", "Not yet")
    refute has_element?(view, "#verify-accept")

    mcp(ctx.builder, "complete_card", %{card: ctx.card.id})
    {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/cards/#{ctx.card}")
    view |> element("#verify-accept") |> render_click()
    assert Repo.get!(Card, ctx.card.id).completed
  end

  test "settings turn it on; off, a card shows no verification", ctx do
    {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/cards/#{ctx.card}")
    refute has_element?(view, "#card-verify")

    {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/settings")
    view |> form("#board-form", board: %{"verify_work" => "true"}) |> render_submit()
    assert Boards.get_board!(ctx.board.id).verify_work
  end

  test "the same token in a runner job is a second agent; the pool field shows when on", ctx do
    {:ok, _} =
      Boards.update_board(ctx.board, %{"verify_work" => true, "verify_pool" => "checkers"})

    mcp(ctx.builder, "complete_card", %{card: ctx.card.id})

    [job] = Repo.all(Slipdock.Runners.Job)
    assert job.kind == "verify" and job.pool == "checkers"

    ctx.builder
    |> put_req_header("x-slipdock-client", "cli")
    |> put_req_header("x-slipdock-agent", "1")
    |> put_req_header("x-slipdock-job", "#{job.id}")
    |> post(~p"/api/cards/#{ctx.card.id}/verify", %{"decision" => "accept"})
    |> json_response(200)

    assert Repo.get!(Card, ctx.card.id).completed

    {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/settings")
    assert has_element?(view, "#board-verify-pool[value='checkers']")
    view |> form("#board-form", board: %{"verify_pool" => ""}) |> render_submit()
    assert Boards.get_board!(ctx.board.id).verify_pool == nil

    {:ok, _} = Boards.update_board(Boards.get_board!(ctx.board.id), %{"verify_work" => false})
    {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/settings")
    refute has_element?(view, "#board-verify-pool")
  end

  test "a rejection over the API counts, and an epic's JSON says a subcard awaits (#1624)",
       ctx do
    {:ok, _} = on(ctx)

    ctx.builder
    |> patch(~p"/api/cards/#{ctx.card.id}", %{"completed" => true})
    |> json_response(200)

    json =
      ctx.checker
      |> post(~p"/api/cards/#{ctx.card.id}/verify", %{"decision" => "reject", "reason" => "No"})
      |> json_response(200)

    assert json["card"]["verify_rejections"] == 1
    assert json["card"]["column"] == "To Do"

    {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/cards/#{ctx.card}")
    assert has_element?(view, "#card-verify-rejections", "rejected 1×")

    # An epic with a pending subcard.
    {:ok, t} = Boards.find_template(nil, "Simple")
    epic = card_fixture(ctx.doing, %{"title" => "Epic"})
    {:ok, sub} = Boards.create_sub_board(epic, t)
    [column | _] = Boards.get_board!(sub.id).columns
    child = card_fixture(column, %{"title" => "Child"})
    ctx.builder |> patch(~p"/api/cards/#{child.id}", %{"completed" => true}) |> json_response(200)

    json = ctx.builder |> get(~p"/api/cards/#{epic.id}") |> json_response(200)
    assert json["card"]["sub_board"]["awaiting"] == 1
    assert json["card"]["rollup"]["awaiting"] == 1
    refute json["card"]["rollup"]["health"] == "done"

    plain = ctx.builder |> get(~p"/api/cards/#{ctx.card.id}") |> json_response(200)
    refute Map.has_key?(plain["card"]["rollup"] || %{}, "awaiting")
  end

  test "the guide describes verifying only when a board has it on", ctx do
    guide = ctx.builder |> get(~p"/api/guide") |> response(200)
    refute guide =~ "**A second agent verifies.**"
    assert guide =~ "`verify_card`"

    {:ok, _} = on(ctx)
    guide = ctx.builder |> get(~p"/api/guide") |> response(200)
    assert guide =~ "**A second agent verifies.**"
    assert guide =~ "verified work: a second agent verifies"
  end
end
