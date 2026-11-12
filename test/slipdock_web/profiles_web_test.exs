defmodule SlipdockWeb.ProfilesWebTest do
  @moduledoc """
  Profiles 1 (#1951) at the doors: the board's `profiles` switch over REST,
  MCP and the settings page; a card's profile set, cleared and refused over
  REST, MCP and the card panel; and the profile shown by the card's JSON,
  get_card, list_cards, the card's front and the ledger line (REST, MCP's
  ledger view and the Ledger page). With the switch off, nothing
  shows on a card that has none.
  """
  use SlipdockWeb.ConnCase, async: true

  import Ecto.Query

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Accounts, Boards, Repo}
  alias Slipdock.Boards.Card

  setup %{user: user} do
    board = board_fixture(%{"name" => "Profiled", "code" => unique_code()}, owner: user)
    [_backlog, todo, doing, _done] = board.columns
    card = card_fixture(todo, %{"title" => "Work"})
    {token, _} = Accounts.create_api_token(user, "bot")

    agent =
      build_conn()
      |> put_req_header("accept", "application/json")
      |> put_req_header("authorization", "Bearer " <> token)

    %{board: board, todo: todo, doing: doing, card: card, agent: agent}
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

  describe "the board's switch" do
    test "PATCH /api/boards turns it on and off, and the board's JSON says so", ctx do
      board = ctx.agent |> get(~p"/api/boards/#{ctx.board.id}") |> json_response(200)
      assert board["board"]["profiles"] == false

      resp =
        ctx.agent
        |> patch(~p"/api/boards/#{ctx.board.id}", %{"profiles" => true})
        |> json_response(200)

      assert resp["board"]["profiles"] == true
      assert Boards.get_board!(ctx.board.id).profiles

      ctx.agent
      |> patch(~p"/api/boards/#{ctx.board.id}", %{"profiles" => false})
      |> json_response(200)

      refute Boards.get_board!(ctx.board.id).profiles
    end

    test "MCP update_board sets it, and list_boards reports it only when on", ctx do
      boards = mcp_json(ctx.agent, "list_boards", %{})["boards"]
      refute Map.has_key?(hd(boards), "profiles")

      mcp_json(ctx.agent, "update_board", %{board: ctx.board.code, profiles: true})
      assert Boards.get_board!(ctx.board.id).profiles

      boards = mcp_json(ctx.agent, "list_boards", %{})["boards"]
      assert hd(boards)["profiles"] == true
    end

    test "the settings page shows the switch and saves it", ctx do
      {:ok, view, _} = live(ctx.conn, agentic_path(ctx.board))
      assert has_element?(view, "#board-profiles")

      view |> form("#agentic-form", board: %{"profiles" => "true"}) |> render_submit()
      assert Boards.get_board!(ctx.board.id).profiles
    end
  end

  describe "a card's profile" do
    test "REST sets it on create and update, clears it, and refuses an unknown one with the list",
         ctx do
      created =
        ctx.agent
        |> post(~p"/api/boards/#{ctx.board.id}/cards", %{"title" => "Docs", "profile" => "docs"})
        |> json_response(201)

      assert created["card"]["profile"] == "docs"

      resp =
        ctx.agent
        |> patch(~p"/api/cards/#{ctx.card.id}", %{"profile" => "security"})
        |> json_response(200)

      assert resp["card"]["profile"] == "security"

      body =
        ctx.agent
        |> patch(~p"/api/cards/#{ctx.card.id}", %{"profile" => "chore"})
        |> json_response(422)

      assert inspect(body["details"]["profile"]) =~ "security, schema, feature, fix, docs, spike"
      assert Repo.get!(Card, ctx.card.id).profile == "security"

      resp =
        ctx.agent
        |> patch(~p"/api/cards/#{ctx.card.id}", %{"profile" => ""})
        |> json_response(200)

      assert resp["card"]["profile"] == nil
    end

    test "MCP create_card and update_card set and clear it; get_card and list_cards show it",
         ctx do
      written =
        mcp_json(ctx.agent, "create_card", %{
          board: ctx.board.code,
          title: "Migrate",
          profile: "schema"
        })

      id = written["card"]["id"] || written["id"]
      assert Repo.get!(Card, id).profile == "schema"

      mcp_json(ctx.agent, "update_card", %{card: ctx.card.id, profile: "fix"})
      assert Repo.get!(Card, ctx.card.id).profile == "fix"

      card = mcp_json(ctx.agent, "get_card", %{card: ctx.card.id})
      assert (card["card"] || card)["profile"] == "fix"

      lines = mcp_json(ctx.agent, "list_cards", %{board: ctx.board.code})["cards"]
      assert Enum.find(lines, &(&1["id"] == ctx.card.id))["profile"] == "fix"

      mcp_json(ctx.agent, "update_card", %{card: ctx.card.id, profile: ""})
      assert Repo.get!(Card, ctx.card.id).profile == nil
    end

    test "list_cards leaves the profile out of a card that has none", ctx do
      lines = mcp_json(ctx.agent, "list_cards", %{board: ctx.board.code})["cards"]
      refute Map.has_key?(Enum.find(lines, &(&1["id"] == ctx.card.id)), "profile")
    end

    test "an agent starting a card over REST on a board with profiles on gets one inferred",
         ctx do
      {:ok, _} = Boards.update_board(ctx.board, %{"profiles" => true})
      {:ok, _} = Boards.Cards.update_card(ctx.card, %{"paths" => "docs/**"})

      ctx.agent
      |> post(~p"/api/cards/#{ctx.card.id}/move", %{"column" => ctx.doing.name})
      |> json_response(200)

      assert Repo.get!(Card, ctx.card.id).profile == "docs"
    end
  end

  describe "the ledger line" do
    setup ctx do
      Repo.update_all(from(c in Card, where: c.id == ^ctx.card.id),
        set: [completed: true, completed_at: DateTime.utc_now(:second), profile: "schema"]
      )

      plain = card_fixture(ctx.todo, %{"title" => "Plain"})

      Repo.update_all(from(c in Card, where: c.id == ^plain.id),
        set: [completed: true, completed_at: DateTime.utc_now(:second)]
      )

      %{plain: plain}
    end

    test "the REST ledger and MCP's ledger view carry the card's profile, nil without one",
         ctx do
      items =
        ctx.agent
        |> get("/api/boards/#{ctx.board.id}/ledger?since=1")
        |> json_response(200)
        |> Map.fetch!("days")
        |> Enum.flat_map(& &1["items"])

      by_id = Map.new(items, &{&1["card"]["id"], &1["card"]})
      assert by_id[ctx.card.id]["profile"] == "schema"
      assert by_id[ctx.plain.id]["profile"] == nil

      mcp_cards =
        ctx.agent
        |> mcp_json("activity", %{"board" => ctx.board.id, "view" => "ledger", "since" => "1"})
        |> Map.fetch!("days")
        |> Enum.flat_map(& &1["items"])
        |> Map.new(&{&1["card"]["id"], &1["card"]["profile"]})

      assert mcp_cards[ctx.card.id] == "schema"
      assert mcp_cards[ctx.plain.id] == nil
    end

    test "the Ledger page shows the profile as one word, and nothing without one", ctx do
      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/ledger?since=1")
      assert view |> element("#ledger-#{ctx.card.id} [data-role=profile]") |> render() =~ "schema"
      refute has_element?(view, "#ledger-#{ctx.plain.id} [data-role=profile]")
    end
  end

  describe "the web app" do
    test "the card panel's select shows only with profiles on or a profile set, and sets it",
         ctx do
      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/cards/#{ctx.card}")
      refute has_element?(view, "#card-profile")

      {:ok, _} = Boards.update_board(ctx.board, %{"profiles" => true})
      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/cards/#{ctx.card}")
      assert has_element?(view, "#card-profile option[value=spike]")

      view |> form("#card-profile-form", card: %{"profile" => "spike"}) |> render_change()

      assert Repo.get!(Card, ctx.card.id).profile == "spike"
      assert has_element?(view, "#card-profile option[value=spike][selected]")
    end

    test "the card's front shows its profile as one word, and nothing without one", ctx do
      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}")
      refute has_element?(view, "#card-#{ctx.card.id} [data-role=profile]")

      {:ok, _} = Boards.Cards.update_card(ctx.card, %{"profile" => "feature"})
      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}")
      assert view |> element("#card-#{ctx.card.id} [data-role=profile]") |> render() =~ "feature"
    end
  end
end
