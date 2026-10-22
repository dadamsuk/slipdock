defmodule SlipdockWeb.CardBordersWebTest do
  @moduledoc """
  A colour on each edge of a card (#1209) through every door: the HTTP API,
  MCP's update_card, the card panel's Borders swatches, and the card's front.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Access, Accounts, Boards, Repo}
  alias Slipdock.Boards.Card

  setup %{user: owner} do
    board = board_fixture(%{}, owner: owner)
    card = card_fixture(hd(board.columns), %{"title" => "Framed"})
    %{board: board, card: card}
  end

  defp edges(card), do: Enum.map(Card.borders(), &Map.get(Repo.reload!(card), &1))

  defp api(user), do: user |> conn_as() |> put_req_header("accept", "application/json")

  describe "API" do
    test "PATCH sets an edge, and the card says each one", ctx do
      assert %{"card" => card} =
               api(ctx.user)
               |> patch("/api/cards/#{ctx.card.id}", %{border_top: "red", border_left: "sky"})
               |> json_response(200)

      assert %{
               "border_top" => "red",
               "border_right" => nil,
               "border_bottom" => nil,
               "border_left" => "sky"
             } = card
    end

    test "a colour outside the palette is a 422 naming the edge", ctx do
      body =
        api(ctx.user)
        |> patch("/api/cards/#{ctx.card.id}", %{border_bottom: "chartreuse"})
        |> json_response(422)

      assert inspect(body) =~ "border_bottom"
      assert edges(ctx.card) == [nil, nil, nil, nil]
    end

    test "a new card can come with its edges", ctx do
      assert %{"card" => card} =
               api(ctx.user)
               |> post("/api/boards/#{ctx.board.id}/cards", %{title: "New", border_right: "amber"})
               |> json_response(201)

      assert card["border_right"] == "amber"
    end
  end

  describe "MCP update_card" do
    defp mcp(user, args) do
      {token, _} = Accounts.create_api_token(user, "claude")

      build_conn()
      |> put_req_header("accept", "application/json")
      |> put_req_header("authorization", "Bearer " <> token)
      |> put_req_header("content-type", "application/json")
      |> post(
        "/mcp",
        Jason.encode!(%{
          jsonrpc: "2.0",
          id: 1,
          method: "tools/call",
          params: %{name: "update_card", arguments: args}
        })
      )
      |> json_response(200)
      |> Map.fetch!("result")
    end

    test "sets and clears edges", ctx do
      result = mcp(ctx.user, %{card: ctx.card.id, border_top: "rose", border_bottom: "teal"})
      assert result["isError"] == false, inspect(result["content"])
      assert edges(ctx.card) == ["rose", nil, "teal", nil]

      assert mcp(ctx.user, %{card: ctx.card.id, border_top: ""})["isError"] == false
      assert edges(ctx.card) == [nil, nil, "teal", nil]
    end

    test "refuses a colour that isn't in the palette", ctx do
      assert mcp(ctx.user, %{card: ctx.card.id, border_left: "chartreuse"})["isError"] == true
      assert edges(ctx.card) == [nil, nil, nil, nil]
    end
  end

  describe "card panel" do
    defp click(view, edge, color) do
      view
      |> element(~s(#card-borders button[phx-value-edge="#{edge}"][phx-value-color="#{color}"]))
      |> render_click()
    end

    test "one edge at a time, then all four, then none", ctx do
      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/cards/#{ctx.card.id}")

      click(view, "top", "red")
      click(view, "left", "sky")
      assert edges(ctx.card) == ["red", nil, nil, "sky"]

      click(view, "all", "amber")
      assert edges(ctx.card) == ~w(amber amber amber amber)
      # The All row picks the colour out once the four agree.
      assert has_element?(
               view,
               ~s(#card-borders button[phx-value-edge="all"][phx-value-color="amber"][aria-pressed="true"])
             )

      click(view, "right", "")
      assert edges(ctx.card) == ["amber", nil, "amber", "amber"]

      click(view, "all", "")
      assert edges(ctx.card) == [nil, nil, nil, nil]
    end

    test "a reader's click changes nothing", ctx do
      reader = user_fixture("reader@example.com")
      {:ok, _} = Access.grant(ctx.board, reader, "read", ctx.user)

      {:ok, view, _} =
        live(log_in_user(build_conn(), reader), ~p"/boards/#{ctx.board}/cards/#{ctx.card.id}")

      click(view, "top", "red")
      assert edges(ctx.card) == [nil, nil, nil, nil]
    end
  end

  describe "card front" do
    test "draws a strip on each coloured edge and none on the others", ctx do
      {:ok, _} = Boards.update_card(ctx.card, %{"border_top" => "red", "border_left" => "sky"})
      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}")

      front = view |> element("#card-#{ctx.card.id} [data-role=card-borders]") |> render()
      assert front =~ ~s(data-edge="top")
      assert front =~ ~s(data-edge="left")
      refute front =~ ~s(data-edge="right")
      refute front =~ ~s(data-edge="bottom")
      assert front =~ Slipdock.Palette.dot("red")
    end

    test "a card with no edge colours has no strips", ctx do
      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}")
      refute has_element?(view, "#card-#{ctx.card.id} [data-role=card-borders]")
    end
  end
end
