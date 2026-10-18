defmodule SlipdockWeb.MCP.CaptureChatPromptTest do
  @moduledoc """
  `capture-this-chat` (W-1805): listed only while chat capture is on, embeds
  the board's lists, tags and cards in progress, and walks capture_chat,
  the preview and the commit in that order.
  """
  use SlipdockWeb.ConnCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.Settings

  setup %{user: user} do
    board = board_fixture(%{"name" => "Plans", "code" => "plans3cc"}, owner: user)
    cols = Map.new(board.columns, &{&1.name, &1})
    tag_fixture(board, "decision")
    stranger = user_fixture("stranger@example.com")
    theirs = board_fixture(%{"name" => "Theirs", "code" => "theirs3cc"}, owner: stranger)
    %{board: board, cols: cols, theirs: theirs}
  end

  defp rpc(conn, method, params) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post("/mcp", Jason.encode!(%{jsonrpc: "2.0", id: 1, method: method, params: params}))
    |> json_response(200)
  end

  defp names(conn),
    do: rpc(conn, "prompts/list", %{})["result"]["prompts"] |> Enum.map(& &1["name"])

  test "the board's lists, tags and in-progress cards, and the steps in order", ctx do
    doing = card_fixture(ctx.cols["In Progress"], %{"title" => "Pricing page"})
    card_fixture(ctx.cols["In Progress"], %{"title" => "Shipped", "completed" => true})
    card_fixture(ctx.cols["To Do"], %{"title" => "Not started"})

    body =
      rpc(ctx.conn, "prompts/get", %{name: "capture-this-chat", arguments: %{board: "plans3cc"}})

    assert %{"result" => %{"messages" => [%{"content" => %{"text" => text}}]}} = body

    assert text =~ "Capture this conversation onto Plans (code plans3cc"
    assert text =~ "Tags: decision"
    assert text =~ "In Progress (1 open, doing)"
    assert text =~ "##{doing.id} Pricing page"
    refute text =~ "Shipped"
    refute text =~ "Not started"

    assert text =~
             ~r/capture_chat with board plans3cc.*get_capture.*commit_capture only when I say so/s

    assert text =~
             ~r/Tools to use: capture_chat, get_capture, resolve_capture_question, commit_capture\.$/
  end

  test "needs a board it can see", ctx do
    assert %{"error" => %{"code" => -32602}} =
             rpc(ctx.conn, "prompts/get", %{name: "capture-this-chat"})

    assert %{"error" => %{"code" => -32602}} =
             rpc(ctx.conn, "prompts/get", %{
               name: "capture-this-chat",
               arguments: %{board: "theirs3cc"}
             })
  end

  test "listed while chat capture is on; gone, and unknown, when it is off", ctx do
    assert "capture-this-chat" in names(ctx.conn)

    {:ok, _} = Settings.update(%{"chat_capture_enabled" => false})
    refute "capture-this-chat" in names(ctx.conn)

    body =
      rpc(ctx.conn, "prompts/get", %{name: "capture-this-chat", arguments: %{board: "plans3cc"}})

    assert body["error"]["message"] == "unknown prompt: capture-this-chat"
  end
end
