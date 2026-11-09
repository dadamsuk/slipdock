defmodule SlipdockWeb.ProfilesTierWebTest do
  @moduledoc """
  The human tier (#1952) at the doors: a tree's tiers set over REST, MCP
  and the settings page (security set to none said loudly), shown in the
  board's JSON; a held card's panel offering Merge and Send back; MCP's
  `verify_card` refusing an agent on a held card; and the Ledger page
  saying who a held card waits for.
  """
  use SlipdockWeb.ConnCase, async: true

  import Ecto.Query
  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Accounts, Actor, Boards, Repo, Verified}
  alias Slipdock.Boards.Card

  setup %{user: user} do
    board = board_fixture(%{"name" => "Tiered", "code" => unique_code()}, owner: user)

    {:ok, board} =
      Boards.update_board(board, %{
        "verify_work" => true,
        "ship_via" => "pull_request",
        "profiles" => true
      })

    [_backlog, _todo, doing, _done] = board.columns
    {token, _} = Accounts.create_api_token(user, "bot")

    agent =
      build_conn()
      |> put_req_header("accept", "application/json")
      |> put_req_header("authorization", "Bearer " <> token)

    %{board: board, doing: doing, agent: agent}
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

  defp mcp_json(conn, tool, args) do
    result = mcp(conn, tool, args)
    assert result["isError"] == false, inspect(result)
    [%{"text" => text}] = result["content"]
    Jason.decode!(text)
  end

  # A schema card an agent built and another accepted: held for a person.
  defp held!(ctx) do
    card = card_fixture(ctx.doing, %{"title" => "Migrate"})
    {:ok, card} = Boards.update_card(card, %{"profile" => "schema"})
    builder = %{Actor.unknown() | kind: "agent", via: "api", user_id: ctx.user.id, agent: "b"}
    checker = %{builder | agent: "c"}

    {:ok, _} =
      Boards.update_card(
        card,
        %{
          "completed" => true,
          "evidence_pr" => "https://github.com/acme/app/pull/3",
          "evidence_commit" => "abc1234"
        },
        actor: builder
      )

    {:ok, held} = Verified.decide(Repo.get!(Card, card.id), "accept", %{}, checker, ctx.user)
    assert held.verify_state == "held"
    held
  end

  describe "setting the tiers" do
    test "PATCH merges them onto the tree's, shows them in the board's JSON, and refuses a bad one",
         ctx do
      board = ctx.agent |> get(~p"/api/boards/#{ctx.board.id}") |> json_response(200)
      assert board["board"]["profile_tiers"]["schema"] == "before_merge"

      resp =
        ctx.agent
        |> patch(~p"/api/boards/#{ctx.board.id}", %{
          "profile_tiers" => %{"spike" => "before_merge"}
        })
        |> json_response(200)

      assert resp["board"]["profile_tiers"]["spike"] == "before_merge"
      assert resp["board"]["profile_tiers"]["schema"] == "before_merge"
      assert Boards.get_board!(ctx.board.id).profile_tiers == %{"spike" => "before_merge"}

      ctx.agent
      |> patch(~p"/api/boards/#{ctx.board.id}", %{"profile_tiers" => %{"spike" => "default"}})
      |> json_response(200)

      assert Boards.get_board!(ctx.board.id).profile_tiers == %{}

      resp =
        ctx.agent
        |> patch(~p"/api/boards/#{ctx.board.id}", %{"profile_tiers" => %{"spike" => "often"}})
        |> json_response(422)

      assert inspect(resp) =~ "none, ledger, before_merge"
    end

    test "with profiles off the board's JSON has no tiers", ctx do
      {:ok, _} = Boards.update_board(ctx.board, %{"profiles" => false})
      board = ctx.agent |> get(~p"/api/boards/#{ctx.board.id}") |> json_response(200)
      assert is_nil(board["board"]["profile_tiers"])
    end

    test "MCP update_board sets them, and says loudly when security is none", ctx do
      out =
        mcp_json(ctx.agent, "update_board", %{
          board: ctx.board.code,
          profile_tiers: %{"security" => "none"}
        })

      assert out["profile_tiers"]["security"] == "none"
      assert [warning] = out["warnings"]
      assert warning =~ "security is set to none"

      result =
        mcp(ctx.agent, "update_board", %{board: ctx.board.code, profile_tiers: %{"x" => "none"}})

      assert result["isError"] == true
    end

    test "the settings page shows a select per profile, warns on security none, and saves", ctx do
      {:ok, view, _} = live(ctx.conn, agentic_path(ctx.board))
      assert has_element?(view, "#board-tier-schema option[value=before_merge][selected]")
      refute has_element?(view, "#board-profile-tiers-warning")

      view
      |> form("#agentic-form", board: %{"profile_tiers" => %{"security" => "none"}})
      |> render_change()

      assert has_element?(view, "#board-profile-tiers-warning")

      view
      |> form("#agentic-form", board: %{"profile_tiers" => %{"security" => "none"}})
      |> render_submit()

      assert Boards.get_board!(ctx.board.id).profile_tiers == %{"security" => "none"}
    end

    test "the settings page has no tiers with profiles off", ctx do
      {:ok, _} = Boards.update_board(ctx.board, %{"profiles" => false})
      {:ok, view, _} = live(ctx.conn, agentic_path(ctx.board))
      refute has_element?(view, "#board-profile-tiers")
    end
  end

  describe "a held card" do
    test "its panel offers Merge and Send back to a person; Merge queues the merge", ctx do
      held = held!(ctx)
      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/cards/#{held}")
      assert has_element?(view, "#card-held")
      assert has_element?(view, "#held-send-back")

      view |> element("#held-merge") |> render_click()
      assert Repo.get!(Card, held.id).verify_state == "merging"
    end

    test "Send back from the panel rejects it with the reason", ctx do
      held = held!(ctx)
      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/cards/#{held}")
      view |> form("#held-send-back", %{"reason" => "not this week"}) |> render_submit()

      card = Repo.get!(Card, held.id)
      assert card.verify_state == "rejected"
      assert card.verify_note =~ "not this week"
    end

    test "MCP verify_card refuses an agent deciding it", ctx do
      held = held!(ctx)
      result = mcp(ctx.agent, "verify_card", %{card: to_string(held.id), decision: "accept"})
      assert result["isError"] == true
      assert inspect(result) =~ "held for a person"
      assert Repo.get!(Card, held.id).verify_state == "held"
    end

    test "the Ledger page says who it waits for", ctx do
      held = held!(ctx)

      Repo.update_all(from(c in Card, where: c.id == ^held.id),
        set: [verify_at: DateTime.utc_now(:second)]
      )

      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/ledger?since=1")

      assert view |> element("#ledger-#{held.id} [data-role=waiting-for]") |> render() =~
               "waiting for"
    end
  end
end
