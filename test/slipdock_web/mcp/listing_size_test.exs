defmodule SlipdockWeb.MCP.ListingSizeTest do
  @moduledoc """
  What an agent pays for a look at a board (#3176). On a board shaped like
  the one measured (15 open cards, 66 in Done, each with a description and
  comments), `get_board` and `list_cards` answer a brief per card, leave the
  done lists out or trimmed unless asked, and send their JSON once,
  compact. `get_card` is where a description and comments are read.
  """
  use SlipdockWeb.ConnCase, async: true

  import Ecto.Query, only: [from: 2]
  import Slipdock.Fixtures

  alias Slipdock.{Boards, Repo}

  # The budget the card set: well under the 300 KB and 186 KB measured.
  @budget 20_000

  # About the size of a real card's description (95 KB over 81 cards).
  @description String.duplicate("A paragraph of what the card is for and why. ", 26)

  setup %{conn: conn, user: user} do
    board = board_fixture(%{"name" => "Sized", "code" => "sized1"}, owner: user)
    cols = Map.new(board.columns, &{&1.name, &1})
    tag = tag_fixture(board, "mcp")

    open =
      for {list, n} <- [{"Backlog", 6}, {"To Do", 6}, {"In Progress", 3}], i <- 1..n do
        card =
          card_fixture(cols[list], %{
            "title" => "#{list} card #{i}: something to build, said in a line",
            "description" => @description
          })

        {:ok, _} = Boards.Comments.add_comment(card, "A comment that says what was found.")
        {:ok, _} = Boards.Cards.set_card_tags(card, [tag])
        card
      end

    base = ~U[2026-11-01 00:00:00Z]

    done =
      for i <- 1..66 do
        card =
          card_fixture(cols["Done"], %{
            "title" => "Done card #{i}: something built, said in a line",
            "description" => @description,
            "completed" => true
          })

        {:ok, _} = Boards.Comments.add_comment(card, "**Done.** What was built and how.")
        # Done one after another, so "newest" is well defined.
        at = DateTime.add(base, i * 3600)
        Repo.update_all(from(c in Boards.Card, where: c.id == ^card.id), set: [completed_at: at])
        card
      end

    %{conn: conn, board: board, open: open, done: done}
  end

  defp call(conn, tool, args) do
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

  defp text(result) do
    assert result["isError"] == false, inspect(result["content"])
    [%{"type" => "text", "text" => text}] = result["content"]
    text
  end

  defp cards_of(board), do: Enum.flat_map(board["lists"], & &1["cards"])
  defp done_list(board), do: Enum.find(board["lists"], &(&1["name"] == "Done"))

  describe "the size of an answer" do
    test "get_board on a board like slipdock is under the budget", ctx do
      bytes = ctx.conn |> call("get_board", %{board: "sized1"}) |> text() |> byte_size()
      assert bytes < @budget, "get_board answered #{bytes} bytes"
    end

    test "list_cards on the same board is under the budget", ctx do
      bytes = ctx.conn |> call("list_cards", %{board: "sized1"}) |> text() |> byte_size()
      assert bytes < @budget, "list_cards answered #{bytes} bytes"
    end

    test "the payload goes once, as compact JSON text", ctx do
      for {tool, args} <- [
            {"get_board", %{board: "sized1"}},
            {"list_cards", %{board: "sized1"}},
            {"get_card", %{card: hd(ctx.open).id}}
          ] do
        result = call(ctx.conn, tool, args)
        refute Map.has_key?(result, "structuredContent"), tool
        text = text(result)
        refute text =~ "\n", "#{tool} is pretty-printed"
        assert is_map(Jason.decode!(text))
      end
    end
  end

  describe "no description or comments in a listing" do
    test "get_board and list_cards leave them out; get_card has them", ctx do
      board = ctx.conn |> call("get_board", %{board: "sized1"}) |> mcp_data()
      listed = ctx.conn |> call("list_cards", %{board: "sized1"}) |> mcp_data()

      for line <- cards_of(board) ++ listed["cards"] do
        refute Map.has_key?(line, "description")
        refute Map.has_key?(line, "comments")
        assert line["title"] =~ "said in a line"
      end

      card = ctx.conn |> call("get_card", %{card: hd(ctx.open).id}) |> mcp_data()
      assert card["description"] == @description
      assert [%{"body" => "A comment that says what was found."}] = card["comments"]
    end

    test "descriptions: true puts each card's description back", ctx do
      board =
        ctx.conn |> call("get_board", %{board: "sized1", descriptions: true}) |> mcp_data()

      listed =
        ctx.conn |> call("list_cards", %{board: "sized1", descriptions: true}) |> mcp_data()

      for line <- cards_of(board) ++ listed["cards"] do
        assert line["description"] == @description
        refute Map.has_key?(line, "comments")
      end
    end

    test "descriptions must be a boolean", ctx do
      for tool <- ~w(get_board list_cards) do
        result = call(ctx.conn, tool, %{board: "sized1", descriptions: "yes"})
        assert result["isError"] == true, tool
      end
    end

    test "a brief keeps what work is picked by", ctx do
      %{"cards" => [line | _]} =
        ctx.conn |> call("list_cards", %{board: "sized1", column: "To Do"}) |> mcp_data()

      assert %{"id" => _, "title" => _, "column" => "To Do", "tags" => ["mcp"]} = line
      assert line["completed"] == false
      assert line["priority"] == "none"
    end
  end

  describe "done lists in get_board" do
    test "show only their newest 5, and say how many were left out", ctx do
      board = ctx.conn |> call("get_board", %{board: "sized1"}) |> mcp_data()
      done = done_list(board)

      newest = ctx.done |> Enum.take(-5) |> Enum.map(& &1.id) |> MapSet.new()
      assert done["cards"] |> Enum.map(& &1["id"]) |> MapSet.new() == newest
      assert done["left_out"] == 61

      # The open lists are whole and say nothing left out.
      todo = Enum.find(board["lists"], &(&1["name"] == "To Do"))
      assert length(todo["cards"]) == 6
      refute Map.has_key?(todo, "left_out")
    end

    test "include_done shows every one", ctx do
      board =
        ctx.conn |> call("get_board", %{board: "sized1", include_done: true}) |> mcp_data()

      done = done_list(board)
      assert length(done["cards"]) == 66
      refute Map.has_key?(done, "left_out")
    end

    test "a dropped list is trimmed as a done one is", ctx do
      {:ok, dropped} =
        Boards.Columns.create_column(ctx.board, %{"name" => "Binned", "category" => "dropped"})

      binned = for i <- 1..7, do: card_fixture(dropped, %{"title" => "Binned #{i}"})

      board = ctx.conn |> call("get_board", %{board: "sized1"}) |> mcp_data()
      list = Enum.find(board["lists"], &(&1["name"] == "Binned"))
      assert length(list["cards"]) == 5
      assert list["left_out"] == 2

      listed = ctx.conn |> call("list_cards", %{board: "sized1"}) |> mcp_data()
      assert listed["done_left_out"] == 66 + 7
      refute Enum.any?(listed["cards"], &(&1["id"] in Enum.map(binned, fn c -> c.id end)))
    end

    test "include_done must be a boolean", ctx do
      result = call(ctx.conn, "get_board", %{board: "sized1", include_done: "yes"})
      assert result["isError"] == true
    end
  end

  describe "done lists in list_cards" do
    test "are left out by default, and counted", ctx do
      result = ctx.conn |> call("list_cards", %{board: "sized1"}) |> mcp_data()

      assert result["total"] == 15
      assert result["done_left_out"] == 66

      assert Enum.sort(Enum.map(result["cards"], & &1["id"])) ==
               Enum.sort(Enum.map(ctx.open, & &1.id))
    end

    test "include_done, a done column or open: false brings them back", ctx do
      all = ctx.conn |> call("list_cards", %{board: "sized1", include_done: true, limit: 200})
      all = mcp_data(all)
      assert all["total"] == 81
      refute Map.has_key?(all, "done_left_out")

      in_done = ctx.conn |> call("list_cards", %{board: "sized1", column: "Done"}) |> mcp_data()
      assert in_done["total"] == 66

      closed = ctx.conn |> call("list_cards", %{board: "sized1", open: false}) |> mcp_data()
      assert closed["total"] == 66
    end
  end
end
