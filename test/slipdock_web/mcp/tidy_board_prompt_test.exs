defmodule SlipdockWeb.MCP.TidyBoardPromptTest do
  @moduledoc """
  `tidy-board` (W-1805): a writer's render runs the gardener first, so the
  embedded suggestions are fresh; a read-only token or a reader gets them as
  they stand, with no run; the walk goes through garden_decide.
  """
  use SlipdockWeb.ConnCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Access, Accounts, Gardener}

  setup %{user: owner} do
    board = board_fixture(%{"name" => "Garden", "code" => "garden4tb"}, owner: owner)
    [_backlog, _todo, doing, _done] = board.columns
    stray = card_fixture(doing, %{"title" => "Stray", "completed" => true})
    %{board: board, owner: owner, stray: stray}
  end

  defp prompt(conn, args) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post(
      "/mcp",
      Jason.encode!(%{
        jsonrpc: "2.0",
        id: 1,
        method: "prompts/get",
        params: %{name: "tidy-board", arguments: args}
      })
    )
    |> json_response(200)
  end

  defp text!(body) do
    assert %{"result" => %{"messages" => [%{"content" => %{"text" => text}}]}} = body
    text
  end

  defp token_conn(user, opts) do
    {token, _} = Accounts.create_api_token(user, "t", opts)
    put_req_header(build_conn(), "authorization", "Bearer " <> token)
  end

  test "a writer's render looks the board over and lists what it found", ctx do
    assert Gardener.last_run(ctx.board) == nil

    text = ctx.conn |> prompt(%{board: "garden4tb"}) |> text!()

    assert %{trigger: "mcp"} = Gardener.last_run(ctx.board)
    [s] = Gardener.list_open(ctx.board)
    assert text =~ "The gardener has just looked the board over."
    assert text =~ "## Open suggestions (1)"
    assert text =~ "suggestion #{s.id} · Complete but not in Done:"
    assert text =~ "(##{ctx.stray.id} Stray)"
    assert text =~ "garden_decide"
    assert text =~ ~r/Tools to use: garden, garden_decide, get_card, read_page\.$/
  end

  test "a clean board says there is nothing to tidy", ctx do
    {:ok, _} = Slipdock.Boards.archive_card(ctx.stray)
    text = ctx.conn |> prompt(%{board: "garden4tb"}) |> text!()
    assert text =~ "## Open suggestions (0)"
    assert text =~ "Nothing to tidy"
  end

  test "a read-only token gets the suggestions as they stand, without a run", ctx do
    conn = token_conn(ctx.owner, scope: "read")
    text = conn |> prompt(%{board: "garden4tb"}) |> text!()
    assert text =~ "never looked this board over"
    assert text =~ "read-only"
    assert Gardener.last_run(ctx.board) == nil

    {:ok, _} = Gardener.run(ctx.board, trigger: "manual")
    text = conn |> prompt(%{board: "garden4tb"}) |> text!()
    assert text =~ "As of the gardener's last look"
    assert text =~ "Complete but not in Done"
    assert %{trigger: "manual"} = Gardener.last_run(ctx.board)
  end

  test "someone the board is shared with to read doesn't start a run", ctx do
    reader = user_fixture("tidy-reader@example.com")
    {:ok, _} = Access.grant(ctx.board, reader, "read", ctx.owner)

    text = reader |> conn_as() |> prompt(%{board: "garden4tb"}) |> text!()
    assert text =~ "never looked this board over"
    assert Gardener.last_run(ctx.board) == nil
  end

  test "a stranger's board, and no board, are -32602", ctx do
    stranger = user_fixture("tidy-stranger@example.com")

    assert %{"error" => %{"code" => -32602}} =
             stranger |> conn_as() |> prompt(%{board: "garden4tb"})

    assert %{"error" => %{"code" => -32602}} = prompt(ctx.conn, %{})
    assert Gardener.last_run(ctx.board) == nil
  end
end
