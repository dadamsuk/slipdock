defmodule SlipdockWeb.FindingsProposeAtTest do
  @moduledoc """
  Promotion by recurrence at every door (#1942): the board's
  `findings_propose_at` in its settings, over REST and MCP, a finding's
  proposal on the Findings page and in its JSON, and the docs that describe
  it. It reads the docs, so it is on `test/repo_checks.txt`.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Accounts, AIStub, Boards, Handbook, Repo}
  alias Slipdock.Findings.{Finding, Promote}

  setup %{user: user} do
    board = board_fixture(%{"name" => "Thresholds", "code" => unique_code()}, owner: user)
    {token, _} = Accounts.create_api_token(user, "bot")

    agent =
      build_conn()
      |> put_req_header("accept", "application/json")
      |> put_req_header("authorization", "Bearer " <> token)

    %{board: board, agent: agent}
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

  test "3 by default; PATCH and MCP update_board set it; out of range is refused", ctx do
    json = ctx.agent |> get(~p"/api/boards/#{ctx.board.id}") |> json_response(200)
    assert json["board"]["findings_propose_at"] == 3

    json =
      ctx.agent
      |> patch(~p"/api/boards/#{ctx.board.id}", %{"findings_propose_at" => 5})
      |> json_response(200)

    assert json["board"]["findings_propose_at"] == 5

    for bad <- [-1, 101] do
      assert %{"details" => %{"findings_propose_at" => [msg]}} =
               ctx.agent
               |> patch(~p"/api/boards/#{ctx.board.id}", %{"findings_propose_at" => bad})
               |> json_response(422)

      assert msg =~ "must be 0 (never)"
    end

    result = mcp(ctx.agent, "update_board", %{board: "#{ctx.board.id}", findings_propose_at: 0})
    assert result["isError"] == false
    assert Boards.get_board!(ctx.board.id).findings_propose_at == 0
  end

  test "board settings show it and save it", ctx do
    {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/settings")
    assert has_element?(view, "#board-findings-propose-at[value='3']")

    view |> form("#board-form", board: %{"findings_propose_at" => "4"}) |> render_submit()
    assert Boards.get_board!(ctx.board.id).findings_propose_at == 4
  end

  test "a finding's proposal is on the Findings page and in its JSON", ctx do
    AIStub.fail_with(503, "down")
    {:ok, _} = Handbook.install(ctx.user, ctx.board)
    card = card_fixture(hd(ctx.board.columns), %{"title" => "Seen"})

    f =
      Repo.insert!(%Finding{
        board_id: ctx.board.id,
        card_id: card.id,
        kind: "gotcha",
        source: "agent",
        text: "a lesson seen thrice",
        count: 3
      })

    {:ok, s} = Promote.check(f.id)

    {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/findings")

    assert has_element?(
             view,
             ~s(#finding-#{f.id} a[data-role=proposal][href="/boards/#{ctx.board.id}/tidy"]),
             "proposal ##{s.id} · SPEC-1"
           )

    %{"findings" => [json]} =
      ctx.agent |> get(~p"/api/boards/#{ctx.board.id}/findings") |> json_response(200)

    assert json["proposal_id"] == s.id and json["proposed_rule"] == "SPEC-1"
  end

  test "the manual, agents.md, the API guide and the Flow help page describe it", ctx do
    squash = &String.replace(&1, ~r/\s+/, " ")
    manual = squash.(File.read!("docs/manual.md"))
    assert manual =~ "**Promotion by recurrence.**"
    assert manual =~ "`slipdock set-board B --findings-propose-at N`"
    assert manual =~ "**Rules drafted from findings.**"

    assert squash.(File.read!("docs/agents.md")) =~ "`findings_propose_at` (3 by default, 0 off)"

    guide = squash.(SlipdockWeb.APIGuide.markdown(user: ctx.user))
    assert guide =~ "A finding counted to the board's `findings_propose_at`"
    assert guide =~ "`proposal_id` and `proposed_rule`"

    {:ok, _view, html} = live(ctx.conn, ~p"/help/agents/flow")
    assert squash.(html) =~ "drafted as a rule on the Tidy-up page"
  end
end
