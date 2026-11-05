defmodule SlipdockWeb.VerifyAuditLiveTest do
  @moduledoc """
  The audit setting's surfaces (#1780): board settings, REST's board update
  and JSON (0..1000), MCP `verify_card`'s agree and disagree, and a job's
  `audit` in its JSON.
  """
  use SlipdockWeb.ConnCase, async: true

  import Ecto.Query
  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Boards, Repo, Runners}
  alias Slipdock.Boards.Card

  setup %{user: user} do
    board = board_fixture(%{"name" => "Audited", "code" => unique_code()}, owner: user)
    {:ok, board} = Boards.update_board(board, %{"verify_work" => true})
    %{board: board}
  end

  defp api(conn), do: put_req_header(conn, "accept", "application/json")

  test "board settings show it with verify on, and save it", ctx do
    {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/settings")
    assert has_element?(view, "#board-verify-audit[value='0']")
    assert render(view) =~ "Audit 1 in N accepted cards"

    view |> form("#board-form", board: %{"verify_audit" => "10"}) |> render_submit()
    assert Boards.get_board!(ctx.board.id).verify_audit == 10

    {:ok, _} = Boards.update_board(Boards.get_board!(ctx.board.id), %{"verify_work" => false})
    {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/settings")
    refute has_element?(view, "#board-verify-audit")
  end

  test "REST sets and shows it; out of range is refused", ctx do
    json =
      ctx.conn
      |> api()
      |> patch(~p"/api/boards/#{ctx.board.code}", %{"verify_audit" => 20})
      |> json_response(200)

    assert json["board"]["verify_audit"] == 20

    for bad <- [-1, 1001] do
      assert %{"details" => %{"verify_audit" => [msg]}} =
               ctx.conn
               |> api()
               |> patch(~p"/api/boards/#{ctx.board.code}", %{"verify_audit" => bad})
               |> json_response(422)

      assert msg =~ "must be 0 (no audits) or N"
    end
  end

  test "MCP and REST take agree and disagree, refused outside an audit job; a job shows audit",
       ctx do
    doing = Enum.find(ctx.board.columns, &(&1.category == "doing"))
    card = card_fixture(doing, %{"title" => "Done work"})

    Repo.update_all(from(c in Card, where: c.id == ^card.id),
      set: [
        verify_state: "accepted",
        completed: true,
        verify_by: %{"kind" => "agent", "agent" => "v"}
      ]
    )

    call = fn args ->
      ctx.conn
      |> api()
      |> put_req_header("content-type", "application/json")
      |> post(
        "/mcp",
        Jason.encode!(%{
          jsonrpc: "2.0",
          id: 1,
          method: "tools/call",
          params: %{name: "verify_card", arguments: Map.put(args, :card, card.id)}
        })
      )
      |> json_response(200)
      |> Map.fetch!("result")
    end

    # MCP is an agent's door: outside the card's audit job it is refused.
    result = call.(%{decision: "agree", reason: "Fine"})
    assert result["isError"] == true
    assert hd(result["content"])["text"] =~ "only from its audit job"

    # REST on an agent's token is refused the same way; a disagreement's
    # reason is checked once it may audit (Slipdock.VerifiedAuditTest).
    assert %{"error" => msg} =
             ctx.conn
             |> api()
             |> post(~p"/api/cards/#{card.id}/verify", %{
               "decision" => "disagree",
               "reason" => "x"
             })
             |> json_response(403)

    assert msg =~ "only from its audit job"

    assert Repo.get!(Card, card.id).verify_state == "accepted"

    {:ok, job} =
      Runners.queue(Repo.get!(Card, card.id), %{
        pool: "loop",
        kind: "verify",
        audit: true,
        prompt: "x"
      })

    shown = ctx.conn |> api() |> get(~p"/api/jobs/#{job.id}") |> json_response(200)
    assert (shown["job"] || shown)["audit"] == true
  end

  test "the guide, docs/agents.md, the manual, the skills and the installers describe audits",
       ctx do
    {:ok, _} = Boards.update_board(ctx.board, %{"verify_pool" => "loop"})
    squash = &String.replace(&1, ~r/\s+/, " ")
    guide = SlipdockWeb.APIGuide.markdown(user: ctx.user) |> squash.()
    assert guide =~ "A board's `verify_audit` (1 in N, 0 none)"
    assert guide =~ "agree|disagree --reason"

    assert squash.(File.read!("docs/agents.md")) =~
             "A board's `verify_audit` (1 in N; 0, the default,"

    assert squash.(File.read!("docs/manual.md")) =~ "**Audits check the checker.**"

    assert File.read!("priv/skills/slipdock-loop/SKILL.md") =~
             "- **An audit** (a verify job with `audit: true`"

    assert File.read!("priv/skills/slipdock/SKILL.md") =~ "slipdock verify <id> agree|disagree"

    for f <- ~w(install.sh install.ps1),
        do: assert(File.read!("priv/runner/" <> f) =~ "cards as audits (never to the runner")
  end
end
