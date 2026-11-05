defmodule SlipdockWeb.VerifyChecksWebTest do
  @moduledoc """
  A verdict in parts at the doors (#1778): REST and MCP `verify_card` take
  `checks`, refuse a rejection with no failing part and an acceptance with a
  failing one, the card's JSON carries `verify_checks`, the card panel lists
  them under Verification, and `verify_card`'s description stays short.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Accounts, Boards, Repo}
  alias Slipdock.Boards.Card

  setup %{user: user} do
    board = board_fixture(%{"name" => "Parts", "code" => unique_code()}, owner: user)
    {:ok, board} = Boards.update_board(board, %{"verify_work" => true})
    doing = Enum.find(board.columns, &(&1.category == "doing"))
    card = card_fixture(doing, %{"title" => "Export"})
    builder = agent(user, "builder")

    builder
    |> patch(~p"/api/cards/#{card.id}", %{"completed" => true})
    |> json_response(200)

    %{board: board, card: card, builder: builder, checker: agent(user, "checker")}
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

  test "REST takes checks, and the card's JSON carries them", ctx do
    json =
      ctx.checker
      |> post(~p"/api/cards/#{ctx.card.id}/verify", %{
        "decision" => "reject",
        "reason" => "Not yet",
        "checks" => ["ask=ok", "bar:1=fail:no header", "suite=10:0"]
      })
      |> json_response(200)

    assert json["card"]["verify_checks"] == %{
             "ask" => "ok",
             "bar" => [%{"item" => "1", "result" => "fail", "note" => "no header"}],
             "suite" => %{"passed" => 10, "failed" => 0}
           }

    shown = ctx.checker |> get(~p"/api/cards/#{ctx.card.id}") |> json_response(200)
    assert shown["card"]["verify_checks"]["ask"] == "ok"
  end

  test "REST refuses a rejection with no failing part, and an unparseable check", ctx do
    assert %{"error" => msg} =
             ctx.checker
             |> post(~p"/api/cards/#{ctx.card.id}/verify", %{
               "decision" => "reject",
               "reason" => "Not yet",
               "checks" => ["bar:1=ok"]
             })
             |> json_response(422)

    assert msg =~ "a rejection names what fails"

    assert %{"error" => msg} =
             ctx.checker
             |> post(~p"/api/cards/#{ctx.card.id}/verify", %{
               "decision" => "accept",
               "checks" => ["bar=ok"]
             })
             |> json_response(422)

    assert msg =~ "needs which one"
    assert Repo.get!(Card, ctx.card.id).verify_state == "pending"
  end

  test "MCP verify_card takes checks; an acceptance with a failing part is refused", ctx do
    result =
      mcp(ctx.checker, "verify_card", %{
        card: ctx.card.id,
        decision: "accept",
        checks: ["bar:1=ok", "rule:ARCH-3=broken:writes around Boards"]
      })

    assert result["isError"] == true
    assert hd(result["content"])["text"] =~ "an acceptance can't carry a failing check: ARCH-3"

    result =
      mcp(ctx.checker, "verify_card", %{
        card: ctx.card.id,
        decision: "accept",
        checks: ["bar:1=ok", "handbook_line=ok"]
      })

    assert result["isError"] == false
    card = Repo.get!(Card, ctx.card.id)
    assert card.completed

    assert card.verify_checks == %{
             "bar" => [%{"item" => "1", "result" => "ok"}],
             "handbook_line" => "ok"
           }
  end

  test "verify_card's description stays under 250 characters and names checks" do
    desc = SlipdockWeb.MCP.Tools.VerifyCard.description()
    assert String.length(desc) < 250
    assert desc =~ "checks"
    assert SlipdockWeb.MCP.Tools.VerifyCard.input_schema().properties.checks.type == "array"
  end

  test "the card panel lists the parts under Verification", ctx do
    ctx.checker
    |> post(~p"/api/cards/#{ctx.card.id}/verify", %{
      "decision" => "reject",
      "reason" => "Two things",
      "checks" => ["ask=misses:the footer", "bar:1=ok", "rule:UX-4=broken:hex in card.ex"]
    })
    |> json_response(200)

    {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/cards/#{ctx.card}")

    assert has_element?(view, "#card-verify-checks")
    assert has_element?(view, "#card-verify-check-0", "the ask")
    assert has_element?(view, "#card-verify-check-0", "misses")
    assert has_element?(view, "#card-verify-check-0", "the footer")
    assert has_element?(view, "#card-verify-check-0 .text-error")
    assert has_element?(view, "#card-verify-check-1", "bar 1")
    assert has_element?(view, "#card-verify-check-1 .text-success")
    assert has_element?(view, "#card-verify-check-2", "UX-4")
    assert has_element?(view, "#card-verify-check-2", "hex in card.ex")
  end

  test "the panel shows no parts while the card awaits verification, or when there are none",
       ctx do
    {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/cards/#{ctx.card}")
    assert has_element?(view, "#card-verify")
    refute has_element?(view, "#card-verify-checks")

    # Rejected and sent back, then submitted again: the old parts stay off.
    ctx.checker
    |> post(~p"/api/cards/#{ctx.card.id}/verify", %{
      "decision" => "reject",
      "reason" => "x",
      "checks" => ["bar:1=fail"]
    })
    |> json_response(200)

    ctx.builder
    |> patch(~p"/api/cards/#{ctx.card.id}", %{"completed" => true})
    |> json_response(200)

    {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/cards/#{ctx.card}")
    assert Repo.get!(Card, ctx.card.id).verify_state == "pending"
    refute has_element?(view, "#card-verify-checks")
  end

  test "the guide, docs/agents.md and the skills describe the parts", ctx do
    guide = SlipdockWeb.APIGuide.markdown(user: ctx.user) |> String.replace(~r/\s+/, " ")
    assert guide =~ "giving the verdict in parts as `checks`"
    assert guide =~ "kept as `verify_checks`"

    agents = File.read!("docs/agents.md")
    assert agents =~ "(`verify_checks`: the ask, each bar item"
    assert agents =~ "--check bar:2=fail:why"

    assert File.read!("priv/skills/slipdock-loop/SKILL.md") =~
             "verdict in parts too, one `--check` each"

    assert File.read!("priv/skills/slipdock/SKILL.md") =~ "# the verdict in parts (repeat --check"

    prompt = Slipdock.Verified.verify_prompt(Repo.get!(Card, ctx.card.id), ctx.board)
    assert prompt =~ "Give the verdict in parts, one `--check` each (MCP `verify_card` `checks`)"
    assert prompt =~ "A rejection names at least one failing part"
    refute prompt =~ "rule:<id>=ok|broken|n/a"
  end
end
