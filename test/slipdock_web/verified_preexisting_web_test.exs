defmodule SlipdockWeb.VerifiedPreexistingWebTest do
  @moduledoc """
  Pre-existing rule hits at the doors (#1945): REST and MCP `verify_card`
  take `rule:<id>=pre-existing:<file>:<line>`, an acceptance carrying one
  stands, the card panel shows it apart from passed and failed parts, and
  the guide, docs, CLI help and skills describe it.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Accounts, Boards, Repo}
  alias Slipdock.Boards.Card

  setup %{user: user} do
    board = board_fixture(%{"name" => "Inherited", "code" => unique_code()}, owner: user)
    {:ok, board} = Boards.update_board(board, %{"verify_work" => true})
    doing = Enum.find(board.columns, &(&1.category == "doing"))
    card = card_fixture(doing, %{"title" => "Export"})
    builder = agent(user, "builder")

    builder
    |> patch(~p"/api/cards/#{card.id}", %{"completed" => true, "evidence" => "built"})
    |> json_response(200)

    %{board: board, card: card, checker: agent(user, "checker")}
  end

  defp agent(user, label) do
    {token, _} = Accounts.create_api_token(user, label)

    build_conn()
    |> put_req_header("accept", "application/json")
    |> put_req_header("authorization", "Bearer " <> token)
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

  test "REST accepts with a pre-existing part; the JSON and the panel show it apart", ctx do
    json =
      ctx.checker
      |> post(~p"/api/cards/#{ctx.card.id}/verify", %{
        "decision" => "accept",
        "reason" => "met",
        "checks" => ["bar:1=ok", "bar:2=fail:x", "rule:UX-4=pre-existing:lib/card.ex:42:hex"]
      })
      |> json_response(422)

    assert json["error"] =~ "bar 2"

    json =
      ctx.checker
      |> post(~p"/api/cards/#{ctx.card.id}/verify", %{
        "decision" => "accept",
        "reason" => "met",
        "checks" => ["bar:1=ok", "rule:UX-4=pre-existing:lib/card.ex:42:hex"]
      })
      |> json_response(200)

    assert json["card"]["verify_state"] == "accepted"

    assert [%{"result" => "pre-existing", "file" => "lib/card.ex", "line" => 42}] =
             json["card"]["verify_checks"]["rules"]

    {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/cards/#{ctx.card}")
    assert has_element?(view, "#card-verify-check-0 .text-success")
    assert has_element?(view, "#card-verify-check-1", "UX-4")
    assert has_element?(view, "#card-verify-check-1", "pre-existing")
    assert has_element?(view, "#card-verify-check-1", "lib/card.ex:42; hex")
    assert has_element?(view, "#card-verify-check-1 .text-warning")
    refute has_element?(view, "#card-verify-check-1 .text-error")
    refute has_element?(view, "#card-verify-check-1 .text-success")
  end

  test "MCP verify_card takes it; a rejection on it alone is refused", ctx do
    result =
      mcp(ctx.checker, "verify_card", %{
        "card" => ctx.card.id,
        "decision" => "reject",
        "reason" => "UX-4 is broken",
        "checks" => ["rule:UX-4=pre-existing:lib/card.ex:42"]
      })

    assert result["isError"]
    assert hd(result["content"])["text"] =~ "is never a rejection"

    result =
      mcp(ctx.checker, "verify_card", %{
        "card" => ctx.card.id,
        "decision" => "accept",
        "reason" => "met",
        "checks" => ["bar:1=ok", "rule:UX-4=pre-existing:lib/card.ex:42"]
      })

    refute result["isError"]
    assert Repo.get!(Card, ctx.card.id).verify_state == "accepted"

    assert [%{source: "verification", kind: "rule"}] =
             Repo.all(Slipdock.Findings.Finding) |> Enum.filter(&(&1.card_id == ctx.card.id))
  end

  test "the guide, docs, CLI help and skills describe pre-existing parts", ctx do
    flat = fn text -> String.replace(text, ~r/\s+/, " ") end
    read = fn path -> path |> File.read!() |> flat.() end

    guide = SlipdockWeb.APIGuide.markdown(user: ctx.user) |> flat.()
    assert guide =~ "`rule:UX-4=pre-existing:lib/x.ex:42` for a rule broken only in lines"
    assert guide =~ "source `rejection`, `verification`"
    assert guide =~ "asking whether the approach, not the fix, is wrong"

    manual = read.("docs/manual.md")
    assert manual =~ "**Rule hits on code the change didn't touch are reported, not rejected.**"
    assert manual =~ "say the approach may be wrong, not the fix"
    assert manual =~ "sources `rejection`, `verification`"

    agents = read.("docs/agents.md")
    assert agents =~ "`rule:<id>=pre-existing:<file>:<line>`: never a rejection"
    assert agents =~ "asks whether the approach, not the fix, is wrong"

    assert read.("cli/help.txt") =~ "rule:UX-4=pre-existing:lib/x.ex:42 is a rule broken"
    assert read.("priv/skills/slipdock/SKILL.md") =~ "# rule:<id>=pre-existing:<file>:<line>"
    assert read.("priv/skills/slipdock-loop/SKILL.md") =~ "`rule:UX-4=pre-existing:<file>:<line>`"

    assert SlipdockWeb.MCP.Tools.VerifyCard.input_schema().properties.checks.description =~
             "pre-existing"
  end
end
