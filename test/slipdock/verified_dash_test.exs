defmodule Slipdock.VerifiedDashTest do
  @moduledoc """
  A bare `-` as a completion's evidence (#2091): `--evidence -` from a
  client that doesn't read stdin sends the dash itself, and the Handbook:
  line and Findings: block that were piped in never arrive. The server
  refuses it at every door (the core, REST as the CLI sends it, MCP's
  complete_card), while real evidence, and evidence that merely starts with
  a dash, go through.
  """
  use SlipdockWeb.ConnCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Accounts, Actor, Boards, Repo, Verified}
  alias Slipdock.Boards.Card

  setup %{user: user} do
    board = board_fixture(%{"name" => "Dashes", "code" => unique_code()}, owner: user)
    {:ok, board} = Boards.update_board(board, %{"evidence_required" => true})
    [_backlog, todo, doing, done] = board.columns
    {token, _} = Accounts.create_api_token(user, "bot")

    api =
      build_conn()
      |> put_req_header("accept", "application/json")
      |> put_req_header("authorization", "Bearer " <> token)

    cli_agent =
      api
      |> put_req_header("x-slipdock-client", "cli")
      |> put_req_header("x-slipdock-agent", "1")

    %{
      board: board,
      todo: todo,
      doing: doing,
      done: done,
      card: card_fixture(doing, %{"title" => "Work"}),
      agent: Actor.runner(user.id, nil, "bot"),
      person: Actor.web(user),
      api: api,
      cli_agent: cli_agent
    }
  end

  defp card(card), do: Repo.get!(Card, card.id)

  defp refusal({:error, %Ecto.Changeset{} = cs}) do
    assert %{evidence: [message]} = Slipdock.DataCase.errors_on(cs)
    message
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

  test "dash?/1: only a dash alone, once trimmed" do
    assert Verified.dash?("-")
    assert Verified.dash?("  -\n")
    refute Verified.dash?("--")
    refute Verified.dash?("- Handbook: no change")
    refute Verified.dash?("-1 flaky test")
    refute Verified.dash?("")
    refute Verified.dash?(nil)
  end

  describe "the core" do
    test "a completion with a bare dash is refused, saying why and what to do", ctx do
      for dash <- ["-", " -\n"] do
        message =
          refusal(
            Boards.update_card(ctx.card, %{"completed" => true, "evidence" => dash},
              actor: ctx.agent
            )
          )

        assert message =~ "was a bare '-'"
        assert message =~ "Pass the text itself"
        assert message =~ "--evidence - from a CLI that reads stdin"
      end

      refute card(ctx.card).completed
      assert card(ctx.card).evidence == nil
    end

    test "refused even with other evidence beside it, and on a board that doesn't ask", ctx do
      assert refusal(
               Boards.update_card(
                 ctx.card,
                 %{"completed" => true, "evidence" => "-", "evidence_commit" => "abc1234"},
                 actor: ctx.agent
               )
             ) =~ "bare '-'"

      {:ok, _} = Boards.update_board(ctx.board, %{"evidence_required" => false})

      assert refusal(
               Boards.update_card(card(ctx.card), %{"completed" => true, "evidence" => "-"},
                 actor: ctx.agent
               )
             ) =~ "bare '-'"

      refute card(ctx.card).completed
    end

    # SPEC-5: a check on agents' work refuses only agents.
    test "a person, the assistant and an automation each go through", ctx do
      for actor <- [ctx.person, Actor.assistant(ctx.user), Actor.automation()] do
        card = card_fixture(ctx.doing, %{"title" => "Not gated #{actor.via}"})

        assert {:ok, %{evidence: "-"}} =
                 Boards.update_card(card, %{"evidence" => "-"}, actor: actor)

        assert {:ok, %{completed: true}} =
                 Boards.update_card(card(card), %{"completed" => true}, actor: actor)
      end
    end

    test "a write that only sets the dash is refused too", ctx do
      assert refusal(Boards.update_card(ctx.card, %{"evidence" => "-"}, actor: ctx.agent)) =~
               "bare '-'"
    end

    test "a card already holding a dash can't complete on it, but can with real evidence",
         ctx do
      held = ctx.card |> Ecto.Changeset.change(evidence: "-") |> Repo.update!()

      assert refusal(Boards.update_card(held, %{"completed" => true}, actor: ctx.agent)) =~
               "bare '-'"

      assert {:ok, %{completed: true, evidence: "Handbook: no change"}} =
               Boards.update_card(
                 held,
                 %{"completed" => true, "evidence" => "Handbook: no change"},
                 actor: ctx.agent
               )
    end

    test "real evidence, and evidence that starts with a dash, go through", ctx do
      for evidence <- ["- Handbook: no change\n- Findings: none", "-- ran mix test", "ran it"] do
        card = card_fixture(ctx.doing, %{"title" => evidence})

        assert {:ok, %{completed: true, evidence: ^evidence}} =
                 Boards.update_card(card, %{"completed" => true, "evidence" => evidence},
                   actor: ctx.agent
                 )
      end
    end

    test "a card created done with a dash is refused", ctx do
      assert {:error, cs} =
               Boards.create_card(
                 ctx.done,
                 %{"title" => "Done already", "evidence" => "-"},
                 actor: ctx.agent
               )

      assert %{evidence: [message]} = Slipdock.DataCase.errors_on(cs)
      assert message =~ "bare '-'"
    end
  end

  describe "the doors" do
    test "REST: the body an old CLI's done sends is a 422 with the message", ctx do
      body =
        ctx.cli_agent
        |> patch(~p"/api/cards/#{ctx.card.id}", %{"completed" => true, "evidence" => "-"})
        |> json_response(422)

      assert inspect(body) =~ "was a bare '-'"
      assert inspect(body) =~ "from a CLI that reads stdin"
      refute card(ctx.card).completed

      ctx.cli_agent
      |> patch(~p"/api/cards/#{ctx.card.id}", %{
        "completed" => true,
        "evidence" => "- Handbook: no change (a test)\n- Findings: none"
      })
      |> json_response(200)

      assert card(ctx.card).completed
    end

    test "MCP complete_card: an error with the message; a leading dash goes through", ctx do
      result = mcp(ctx.api, "complete_card", %{card: ctx.card.id, evidence: "-"})
      assert result["isError"] == true
      assert [%{"text" => text}] = result["content"]
      assert text =~ "was a bare '-'"
      refute card(ctx.card).completed

      result =
        mcp(ctx.api, "complete_card", %{card: ctx.card.id, evidence: "- Handbook: no change"})

      assert result["isError"] == false
      assert card(ctx.card).completed
    end
  end
end
