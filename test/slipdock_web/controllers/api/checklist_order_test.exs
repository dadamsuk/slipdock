defmodule SlipdockWeb.API.ChecklistOrderTest do
  @moduledoc """
  `POST /api/checklist/:item_id/move {before}` (#1752): a card's or a page's
  checklist item put before another of its own, or last; anything else is
  refused and moves nothing.
  """
  use SlipdockWeb.ConnCase, async: true

  import Slipdock.Fixtures
  alias Slipdock.{Access, Boards}

  setup %{conn: conn, user: user} do
    board = board_fixture(%{"name" => "API Order", "code" => "apiorder"}, owner: user)
    card = card_fixture(hd(board.columns), %{"title" => "Ordered"})

    items =
      for text <- ~w(one two three) do
        {:ok, item} = Boards.add_checklist_item(card, text)
        item
      end

    %{
      conn: put_req_header(conn, "accept", "application/json"),
      board: board,
      card: card,
      items: items
    }
  end

  defp texts(conn, card) do
    %{"card" => %{"checklist" => %{"items" => items}}} =
      conn |> get("/api/cards/#{card.id}") |> json_response(200)

    Enum.map(items, & &1["text"])
  end

  test "before another item answers the checklist in its new order", ctx do
    [one, _, three] = ctx.items

    assert %{"items" => items} =
             ctx.conn
             |> post("/api/checklist/#{three.id}/move", %{before: one.id})
             |> json_response(200)

    assert Enum.map(items, &{&1["text"], &1["position"]}) ==
             [{"three", 0}, {"one", 1}, {"two", 2}]

    assert texts(ctx.conn, ctx.card) == ~w(three one two)
  end

  test "with no before, or a null one, to the end", ctx do
    [one, two, _] = ctx.items
    assert ctx.conn |> post("/api/checklist/#{one.id}/move", %{}) |> json_response(200)
    assert texts(ctx.conn, ctx.card) == ~w(two three one)

    assert ctx.conn |> post("/api/checklist/#{two.id}/move", %{before: nil}) |> json_response(200)
    assert texts(ctx.conn, ctx.card) == ~w(three one two)
  end

  test "an item of another card is refused, and nothing moves", ctx do
    other = card_fixture(hd(ctx.board.columns), %{"title" => "Other"})
    {:ok, theirs} = Boards.add_checklist_item(other, "theirs")
    [one | _] = ctx.items

    assert %{"error" => error} =
             ctx.conn
             |> post("/api/checklist/#{one.id}/move", %{before: theirs.id})
             |> json_response(404)

    assert error =~ "same card or page"
    assert texts(ctx.conn, ctx.card) == ~w(one two three)
  end

  test "an unknown item is a 404", ctx do
    assert ctx.conn |> post("/api/checklist/0/move", %{}) |> json_response(404)
    assert ctx.conn |> post("/api/checklist/nope/move", %{}) |> json_response(404)
  end

  test "a page's checklist reorders through the same route", ctx do
    %{"page" => %{"id" => page_id}} =
      ctx.conn |> post("/api/boards/apiorder/pages", %{title: "Spec"}) |> json_response(201)

    %{"item" => %{"id" => a}} =
      ctx.conn |> post("/api/pages/#{page_id}/checklist", %{text: "a"}) |> json_response(201)

    %{"item" => %{"id" => b}} =
      ctx.conn |> post("/api/pages/#{page_id}/checklist", %{text: "b"}) |> json_response(201)

    assert %{"items" => [%{"id" => ^b}, %{"id" => ^a}]} =
             ctx.conn |> post("/api/checklist/#{b}/move", %{before: a}) |> json_response(200)
  end

  test "a reader of the board can't reorder", ctx do
    owner = user_fixture("order-api-owner@example.com")
    shared = board_fixture(%{"name" => "Theirs"}, owner: owner)
    card = card_fixture(hd(shared.columns), %{"title" => "Theirs"})
    {:ok, a} = Boards.add_checklist_item(card, "a")
    {:ok, _} = Boards.add_checklist_item(card, "b")
    {:ok, _} = Access.grant(shared, ctx.user, "read", owner)

    assert ctx.conn |> post("/api/checklist/#{a.id}/move", %{}) |> json_response(403)
    assert texts(ctx.conn, card) == ~w(a b)
  end
end
