defmodule SlipdockWeb.VerifiedReverifyWebTest do
  @moduledoc """
  Partial re-verify at the doors (#1944): REST takes `=carried` for a part
  that passed before, the card panel shows a carried part with the commit it
  was carried from, and the guide, the docs and the skills describe it.
  """
  use SlipdockWeb.ConnCase, async: true

  import Slipdock.DocsFacts, only: [assert_states: 2]

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Accounts, Boards}

  setup %{user: user} do
    board = board_fixture(%{"name" => "Carried", "code" => unique_code()}, owner: user)
    {:ok, board} = Boards.update_board(board, %{"verify_work" => true})
    doing = Enum.find(board.columns, &(&1.category == "doing"))
    card = card_fixture(doing, %{"title" => "Export"})

    %{board: board, card: card, builder: agent(user, "builder"), checker: agent(user, "checker")}
  end

  defp agent(user, label) do
    {token, _} = Accounts.create_api_token(user, label)

    build_conn()
    |> put_req_header("accept", "application/json")
    |> put_req_header("authorization", "Bearer " <> token)
  end

  defp submit(ctx, sha) do
    ctx.builder
    |> patch(~p"/api/cards/#{ctx.card.id}", %{
      "completed" => true,
      "evidence" => "built",
      "evidence_commit" => sha
    })
    |> json_response(200)
  end

  defp verify(ctx, params, status \\ 200) do
    ctx.checker
    |> post(~p"/api/cards/#{ctx.card.id}/verify", params)
    |> json_response(status)
  end

  test "REST carries a passed part; the card's JSON and panel show where from", ctx do
    submit(ctx, "abc1234567")

    verify(ctx, %{
      "decision" => "reject",
      "reason" => "bar 2: no header",
      "checks" => ["ask=ok", "bar:1=ok", "bar:2=fail:no header"]
    })

    submit(ctx, "fed9876543")

    # A failed part can't be carried.
    assert verify(ctx, %{"decision" => "accept", "checks" => ["bar:2=carried"]}, 422)["error"] =~
             "can't be carried"

    json = verify(ctx, %{"decision" => "accept", "checks" => ["bar:1=carried", "bar:2=ok"]})
    checks = json["card"]["verify_checks"]
    assert checks["judged_at"] == "fed9876543"
    assert checks["carried"] == %{"ask" => "abc1234567"}
    assert %{"carried_from" => "abc1234567"} = Enum.find(checks["bar"], &(&1["item"] == "1"))

    {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/cards/#{ctx.card}")
    assert has_element?(view, "#card-verify-check-0", "the ask")
    assert has_element?(view, "#card-verify-check-0", "carried from abc1234")
    assert has_element?(view, "#card-verify-check-1", "bar 1")
    assert has_element?(view, "#card-verify-check-1", "carried from abc1234")
    assert has_element?(view, "#card-verify-check-1 .text-success")
    refute has_element?(view, "#card-verify-check-2", "carried")
  end

  test "the guide, the docs and both skills describe carried parts", ctx do
    guide = SlipdockWeb.APIGuide.markdown(user: ctx.user) |> String.replace(~r/\s+/, " ")
    assert_states(guide, "A card resubmitted after a rejection is judged on what changed")
    assert guide =~ "(`bar:1=carried`, or left out)"
    assert guide =~ "an audit carries nothing"

    flat = fn path -> path |> Slipdock.DocsText.read!() |> String.replace(~r/\s+/, " ") end

    assert_states(flat.("docs/manual.md"), "**A resubmission is judged on what changed.**")
    assert flat.("docs/manual.md") =~ "shown as *carried from abc1234*"
    assert flat.("docs/agents.md") =~ "shown as *carried from <sha>*"

    assert_states(
      flat.("docs/agents.md"),
      "The builder's resubmission evidence names the rejected commit and what changed since."
    )

    loop = flat.("priv/skills/slipdock-loop/SKILL.md")
    assert_states(loop, "names the rejected commit and what changed since")
    # The verifier's side is one of the skill's references (#3004).
    verifying = flat.("priv/skills/slipdock-loop/references/verifying.md")
    assert_states(verifying, "**A resubmission** (the prompt says the card was judged before")
    assert verifying =~ "An audit carries nothing."

    assert_states(
      flat.("priv/skills/slipdock-work/SKILL.md"),
      "Its new evidence names the rejected commit and what changed since"
    )

    assert SlipdockWeb.MCP.Tools.VerifyCard.input_schema().properties.checks.description =~
             "=carried"
  end
end
