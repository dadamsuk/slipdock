defmodule SlipdockWeb.MCP.ListCardsPagingTest do
  @moduledoc """
  `list_cards` pages past its 200-card cap (#3654): `offset` picks the page,
  and the answer's `next_offset` says where the next one starts, so a client
  following it reads every card on a board bigger than one page.
  """
  use SlipdockWeb.ConnCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.Boards

  @cards 205

  setup %{conn: conn, user: user} do
    board = board_fixture(%{"name" => "Big", "code" => "big205"}, owner: user)
    column = hd(board.columns)
    cards = for n <- 1..@cards, do: card_fixture(column, %{"title" => "Card #{n}"})
    %{conn: conn, cards: cards}
  end

  defp call(conn, args) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post(
      "/mcp",
      Jason.encode!(%{
        jsonrpc: "2.0",
        id: 1,
        method: "tools/call",
        params: %{name: "list_cards", arguments: Map.put(args, :board, "big205")}
      })
    )
    |> json_response(200)
    |> Map.fetch!("result")
  end

  defp ok!(result) do
    assert result["isError"] == false, inspect(result["content"])
    mcp_data(result)
  end

  defp error!(result) do
    assert result["isError"] == true
    [%{"text" => text}] = result["content"]
    text
  end

  defp ids(page), do: Enum.map(page["cards"], & &1["id"])

  test "the first page holds 200 and points at the rest", ctx do
    page = ctx.conn |> call(%{limit: 200}) |> ok!()

    assert length(page["cards"]) == 200
    assert page["total"] == @cards
    assert page["offset"] == 0
    assert page["truncated"] == true
    assert page["next_offset"] == 200
    assert ids(page) == ctx.cards |> Enum.take(200) |> Enum.map(& &1.id)
  end

  test "a limit over 200 is still one page of 200", ctx do
    page = ctx.conn |> call(%{limit: 500}) |> ok!()
    assert length(page["cards"]) == 200
    assert page["next_offset"] == 200
  end

  test "offset: next_offset gives the last 5, and nothing left", ctx do
    page = ctx.conn |> call(%{limit: 200, offset: 200}) |> ok!()

    assert ids(page) == ctx.cards |> Enum.drop(200) |> Enum.map(& &1.id)
    assert page["offset"] == 200
    assert page["truncated"] == false
    assert Map.has_key?(page, "next_offset") and page["next_offset"] == nil
  end

  test "following next_offset reads every card once, in list order", ctx do
    read =
      Stream.unfold(0, fn
        nil ->
          nil

        offset ->
          ctx.conn |> call(%{offset: offset}) |> ok!() |> then(&{ids(&1), &1["next_offset"]})
      end)
      |> Enum.to_list()

    # The default page is 50: 50, 50, 50, 50, 5.
    assert Enum.map(read, &length/1) == [50, 50, 50, 50, 5]
    assert List.flatten(read) == Enum.map(ctx.cards, & &1.id)
  end

  test "an offset past the end is an empty page, not an error", ctx do
    for offset <- [@cards, 1000] do
      page = ctx.conn |> call(%{offset: offset}) |> ok!()

      assert page["cards"] == []
      assert page["total"] == @cards
      assert page["truncated"] == false
      assert page["next_offset"] == nil
    end
  end

  test "a negative or non-integer offset is an error", ctx do
    for offset <- [-1, "10", 1.5, true] do
      assert ctx.conn |> call(%{offset: offset}) |> error!() =~
               "offset must be 0 or a positive whole number"
    end
  end

  test "offset pages the filtered cards, not the board", ctx do
    completed = Enum.take(ctx.cards, 3)

    for card <- completed,
        do: {:ok, _} = Boards.Cards.update_card(card, %{"completed" => true})

    page = ctx.conn |> call(%{open: true, limit: 200, offset: 200}) |> ok!()

    assert page["total"] == @cards - 3
    assert ids(page) == ctx.cards |> Enum.drop(203) |> Enum.map(& &1.id)
    assert page["next_offset"] == nil

    first = ctx.conn |> call(%{open: true, limit: 200}) |> ok!()
    assert first["next_offset"] == 200
    refute Enum.any?(ids(first), &(&1 in Enum.map(completed, fn c -> c.id end)))
  end

  test "offset with full: true pages cards in full", ctx do
    page = ctx.conn |> call(%{full: true, offset: 180}) |> ok!()

    # A full page is 20 unless limit says otherwise.
    assert ids(page) == ctx.cards |> Enum.slice(180, 20) |> Enum.map(& &1.id)
    assert page["next_offset"] == 200
    assert Enum.all?(page["cards"], &Map.has_key?(&1, "comments"))

    last = ctx.conn |> call(%{full: true, offset: 200}) |> ok!()
    assert length(last["cards"]) == 5
    assert last["truncated"] == false
    assert last["next_offset"] == nil
  end
end
