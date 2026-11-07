defmodule SlipdockWeb.AgenticBuildingTest do
  @moduledoc """
  Agentic Building (#2011): the board's one switch at every door (REST,
  JSON, MCP `update_board` and `list_boards`), the board menu's item shown
  and hidden with it, the page's access rules, its summary strip, the
  warning when it is turned off with rules still set, a sub-board's
  root-only settings read-only, the settings that left the Features tab,
  and the migration's backfill.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Access, Accounts, AgenticBuilding, Boards, Repo}
  alias Slipdock.Boards.Board

  setup %{user: user} do
    board = board_fixture(%{"name" => "Agents", "code" => unique_code()}, owner: user)
    {token, _} = Accounts.create_api_token(user, "bot")

    agent =
      build_conn()
      |> put_req_header("accept", "application/json")
      |> put_req_header("authorization", "Bearer " <> token)

    %{board: board, agent: agent}
  end

  defp turn_on(board, attrs \\ %{}) do
    {:ok, board} =
      Boards.update_board(Boards.get_board!(board.id), Map.put(attrs, "agentic_building", true))

    board
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

  describe "live_rules/1" do
    test "a fresh board has none; each setting away from its default is named", ctx do
      assert AgenticBuilding.live_rules(ctx.board) == []

      board = %{
        ctx.board
        | verify_work: true,
          lane_mode: "advise",
          shared_paths: ["docs/**"],
          wait_routes: %{"ux" => [1]},
          job_log_hours: 6,
          findings_propose_at: 0
      }

      assert AgenticBuilding.live_rules(board) == [
               "A second agent verifies",
               "Lanes",
               "Shared paths",
               "Findings promotion",
               "Who gets asked",
               "Job log retention"
             ]
    end
  end

  describe "the migration's backfill" do
    test "turns it on where a setting is set, and leaves a plain board off", ctx do
      plain = board_fixture(%{"name" => "Plain", "code" => unique_code()}, owner: ctx.user)
      lanes = board_fixture(%{"name" => "Lanes", "code" => unique_code()}, owner: ctx.user)
      routed = board_fixture(%{"name" => "Routed", "code" => unique_code()}, owner: ctx.user)
      {:ok, _} = Boards.update_board(lanes, %{"lane_mode" => "hold"})
      Repo.update!(Ecto.Changeset.change(routed, wait_routes: %{"ux" => [ctx.user.id]}))
      {:ok, _} = Boards.update_board(ctx.board, %{"handoff_label" => "Where it got to"})

      Repo.query!(AgenticBuilding.backfill_sql())

      assert Repo.get!(Board, lanes.id).agentic_building
      assert Repo.get!(Board, routed.id).agentic_building
      assert Repo.get!(Board, ctx.board.id).agentic_building
      refute Repo.get!(Board, plain.id).agentic_building
    end

    test "the migration runs that same text" do
      [migration] = Path.wildcard("priv/repo/migrations/*_add_board_agentic_building.exs")
      assert File.read!(migration) =~ "execute Slipdock.AgenticBuilding.backfill_sql()"
    end
  end

  describe "REST and MCP" do
    test "off by default; PATCH turns it on and the JSON says so", ctx do
      json = ctx.agent |> get(~p"/api/boards/#{ctx.board.id}") |> json_response(200)
      assert json["board"]["agentic_building"] == false

      json =
        ctx.agent
        |> patch(~p"/api/boards/#{ctx.board.id}", %{"agentic_building" => true})
        |> json_response(200)

      assert json["board"]["agentic_building"] == true
      refute Map.has_key?(json, "warnings")
      assert Boards.get_board!(ctx.board.id).agentic_building
    end

    test "PATCH off with rules set warns and names them; the rules stay", ctx do
      turn_on(ctx.board, %{"verify_work" => true, "automation_wip" => true})

      json =
        ctx.agent
        |> patch(~p"/api/boards/#{ctx.board.id}", %{"agentic_building" => false})
        |> json_response(200)

      assert [warning] = json["warnings"]
      assert warning =~ "A second agent verifies"
      assert warning =~ "WIP limits holding automated work"
      board = Boards.get_board!(ctx.board.id)
      refute board.agentic_building
      assert board.verify_work and board.automation_wip
    end

    test "PATCH off with nothing set says nothing more", ctx do
      turn_on(ctx.board)

      json =
        ctx.agent
        |> patch(~p"/api/boards/#{ctx.board.id}", %{"agentic_building" => false})
        |> json_response(200)

      refute Map.has_key?(json, "warnings")
    end

    test "a writer who isn't the owner can't change it", ctx do
      writer = user_fixture("agentic-1-#{System.unique_integer([:positive])}@example.com")
      {:ok, _} = Access.grant(ctx.board, writer, "write", ctx.user)
      {token, _} = Accounts.create_api_token(writer, "w")

      build_conn()
      |> put_req_header("accept", "application/json")
      |> put_req_header("authorization", "Bearer " <> token)
      |> patch(~p"/api/boards/#{ctx.board.id}", %{"agentic_building" => true})
      |> json_response(403)

      refute Boards.get_board!(ctx.board.id).agentic_building
    end

    test "MCP update_board sets it, warns turning it off, and list_boards shows it", ctx do
      json =
        mcp_json(ctx.agent, "update_board", %{board: "#{ctx.board.id}", agentic_building: true})

      assert Boards.get_board!(ctx.board.id).agentic_building
      refute Map.has_key?(json, "warnings")

      %{"boards" => boards} = mcp_json(ctx.agent, "list_boards", %{})
      assert Enum.find(boards, &(&1["id"] == ctx.board.id))["agentic_building"] == true

      {:ok, _} = Boards.update_board(Boards.get_board!(ctx.board.id), %{"lane_mode" => "hold"})

      json =
        mcp_json(ctx.agent, "update_board", %{board: "#{ctx.board.id}", agentic_building: false})

      assert Enum.any?(json["warnings"], &(&1 =~ "Lanes"))
      refute Boards.get_board!(ctx.board.id).agentic_building
    end
  end

  describe "the board menu" do
    test "no Agentic Building item while it is off", ctx do
      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}")
      refute has_element?(view, "#board-share-agentic")
    end

    test "the item opens the page while it is on", ctx do
      turn_on(ctx.board)
      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}")
      assert has_element?(view, ~s(#board-share-agentic[href="/boards/#{ctx.board.id}/agentic"]))
      assert has_element?(view, "#board-share-menu-agentic")
    end

    test "someone who can't manage the board doesn't get the item", ctx do
      turn_on(ctx.board)
      writer = user_fixture("agentic-2-#{System.unique_integer([:positive])}@example.com")
      {:ok, _} = Access.grant(ctx.board, writer, "write", ctx.user)
      {:ok, view, _} = live(conn_as(writer), ~p"/boards/#{ctx.board}")
      refute has_element?(view, "#board-share-agentic")
    end

    test "the wiki's menu has it too", ctx do
      turn_on(ctx.board)
      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/wiki")
      assert has_element?(view, "#board-share-agentic")
    end
  end

  describe "the page" do
    test "off sends the owner to Board settings' Features tab", ctx do
      assert {:error, {:live_redirect, %{to: to}}} =
               live(ctx.conn, ~p"/boards/#{ctx.board}/agentic")

      assert to == "/boards/#{ctx.board.id}/settings?tab=features"
    end

    test "off sends a reader back to the board", ctx do
      reader = user_fixture("agentic-3-#{System.unique_integer([:positive])}@example.com")
      {:ok, _} = Access.grant(ctx.board, reader, "read", ctx.user)

      assert {:error, {:live_redirect, %{to: to}}} =
               live(conn_as(reader), ~p"/boards/#{ctx.board}/agentic")

      assert to == "/boards/#{ctx.board.id}"
    end

    test "someone with no access is refused", ctx do
      turn_on(ctx.board)

      assert {:error, {:live_redirect, %{to: "/"}}} =
               live(
                 conn_as(
                   user_fixture("agentic-4-#{System.unique_integer([:positive])}@example.com")
                 ),
                 ~p"/boards/#{ctx.board}/agentic"
               )
    end

    test "the owner sees every section, and the strip says which rules are on", ctx do
      turn_on(ctx.board, %{
        "verify_work" => true,
        "verify_pool" => "verify",
        "lane_mode" => "advise"
      })

      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/agentic")

      assert has_element?(view, "h1", "Agentic Building")

      for section <- ~w(verified lanes profiles questions handoffs findings runners),
          do: assert(has_element?(view, "#agentic-#{section}"))

      assert has_element?(view, ~s(#agentic-rule-verify[data-on="true"]), "pool verify")
      assert has_element?(view, ~s(#agentic-rule-lanes[data-on="true"]), "advise")
      assert has_element?(view, ~s(#agentic-rule-bar[data-on="false"]))
      assert has_element?(view, ~s(#agentic-rule-routes[data-on="false"]))
      refute has_element?(view, "#agentic-rule-routes", "of 5")
      assert has_element?(view, ~s(#agentic-rule-verify[href="#agentic-verified"]))
      assert has_element?(view, "#agentic-verified [data-role=section-count]", "1 of 3 on")
      assert has_element?(view, "#agentic-save-button")
      refute has_element?(view, "fieldset[disabled]")
    end

    test "the verify options open as the switch is ticked, before it is saved", ctx do
      turn_on(ctx.board)
      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/agentic")
      refute has_element?(view, "#agentic-verify-options")

      view |> form("#agentic-form", board: %{"verify_work" => "true"}) |> render_change()
      assert has_element?(view, "#board-verify-pool")
      refute Boards.get_board!(ctx.board.id).verify_work
    end

    test "saving keeps the owner on the page, says so, and a bad value is shown", ctx do
      turn_on(ctx.board)
      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/agentic")

      html =
        view
        |> form("#agentic-form", board: %{"bar_required" => "true", "automation_wip" => "true"})
        |> render_submit()

      assert html =~ "Saved."
      board = Boards.get_board!(ctx.board.id)
      assert board.bar_required and board.automation_wip
      assert has_element?(view, ~s(#agentic-rule-bar[data-on="true"]))

      html =
        view
        |> form("#agentic-form", board: %{"findings_propose_at" => "500"})
        |> render_submit()

      assert html =~ "must be 0 (never)"
      assert Boards.get_board!(ctx.board.id).findings_propose_at == 3
    end

    test "only the page's own settings are saved from it", ctx do
      turn_on(ctx.board)
      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/agentic")

      render_submit(view, "save", %{"board" => %{"name" => "Renamed", "bar_required" => "true"}})
      board = Boards.get_board!(ctx.board.id)
      assert board.name == "Agents"
      assert board.bar_required
    end

    test "a reader sees it read-only and can't save", ctx do
      turn_on(ctx.board)
      reader = user_fixture("agentic-5-#{System.unique_integer([:positive])}@example.com")
      {:ok, _} = Access.grant(ctx.board, reader, "read", ctx.user)
      {:ok, view, _} = live(conn_as(reader), ~p"/boards/#{ctx.board}/agentic")

      assert has_element?(view, "#agentic-read-only")
      assert has_element?(view, "fieldset[disabled] #board-bar-required")
      refute has_element?(view, "#agentic-save")
      refute has_element?(view, "#agentic-board-settings")

      render_submit(view, "save", %{"board" => %{"bar_required" => "true"}})
      refute Boards.get_board!(ctx.board.id).bar_required
    end

    test "a sub-board shows the human tier read-only, linking to the root's page", ctx do
      board = turn_on(ctx.board, %{"profiles" => true})
      {:ok, _} = Boards.update_board(board, %{"profile_tiers" => %{"docs" => "before_merge"}})
      card = card_fixture(hd(board.columns), %{"title" => "Epic"})
      {:ok, t} = Boards.find_template(nil, "Simple")
      {:ok, sub} = sub_board(card, t)
      assert sub.agentic_building

      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{sub}/agentic")
      refute has_element?(view, "#board-tier-docs")
      assert has_element?(view, "#board-profile-tiers-read", "a person merges it")

      assert has_element?(
               view,
               ~s(#board-profile-tiers [data-role=set-on-root] a[href="/boards/#{board.id}/agentic"])
             )
    end
  end

  describe "Board settings" do
    test "Features has the switch and none of the settings that moved", ctx do
      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/settings?tab=features")
      assert has_element?(view, "#board-agentic-building")
      refute has_element?(view, "#board-agentic-open")

      for id <- ~w(board-verify-work board-lanes board-profiles board-route-ux
                   board-handoff-label board-findings-propose-at board-automation-wip
                   board-job-log-hours),
          do: refute(has_element?(view, "##{id}"))

      assert has_element?(view, "#board-delivery-metrics")
      assert has_element?(view, "#board-show-pulse")
    end

    test "ticking it and saving turns it on; the page is linked then", ctx do
      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/settings?tab=features")
      view |> form("#board-form", board: %{"agentic_building" => "true"}) |> render_submit()
      assert Boards.get_board!(ctx.board.id).agentic_building

      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/settings?tab=features")
      assert has_element?(view, ~s(#board-agentic-open[href="/boards/#{ctx.board.id}/agentic"]))
    end

    test "unticking it with rules set warns, names them, and saves no rule", ctx do
      turn_on(ctx.board, %{"evidence_required" => true})
      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/settings?tab=features")
      refute has_element?(view, "#board-agentic-warning")

      view |> form("#board-form", board: %{"agentic_building" => "false"}) |> render_change()
      assert has_element?(view, "#board-agentic-warning", "Evidence on completion")

      view |> form("#board-form", board: %{"agentic_building" => "false"}) |> render_submit()
      board = Boards.get_board!(ctx.board.id)
      refute board.agentic_building
      assert board.evidence_required
    end
  end
end
