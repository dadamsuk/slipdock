defmodule SlipdockWeb.PauseAPITest do
  @moduledoc """
  The brake through the doors agents and scripts use (#1116): REST `POST`
  and `DELETE /api/boards/:board/pause`, MCP `manage_automation`
  pause/resume, and `paused` on get_board, list_cards and the board and
  cards answers. Owner-only, a reason required, and resuming a person's.
  """
  use SlipdockWeb.ConnCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Accounts, Repo, Runners}

  setup %{user: user} do
    user = user |> Ecto.Changeset.change(name: "David") |> Repo.update!()
    board = board_fixture(%{"name" => "Brake API"}, owner: user)
    [_backlog, todo, _doing, _done] = board.columns

    {:ok, runner, runner_token} =
      Runners.create_runner(board, %{"name" => "box", "pool" => "dev"})

    %{user: user, board: board, todo: todo, runner: runner, runner_token: runner_token}
  end

  defp with_token(user, label, headers \\ []) do
    {token, _} = Accounts.create_api_token(user, label)

    Enum.reduce(
      headers,
      build_conn()
      |> put_req_header("accept", "application/json")
      |> put_req_header("authorization", "Bearer " <> token),
      fn {k, v}, conn -> put_req_header(conn, k, v) end
    )
  end

  @cli [{"x-slipdock-client", "cli"}]

  defp mcp(conn, name, args) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post(
      "/mcp",
      Jason.encode!(%{
        jsonrpc: "2.0",
        id: 1,
        method: "tools/call",
        params: %{name: name, arguments: args}
      })
    )
    |> json_response(200)
    |> Map.fetch!("result")
  end

  defp mcp_json(conn, name, args) do
    %{"content" => [%{"text" => text}]} = mcp(conn, name, args)
    Jason.decode!(text)
  end

  defp mcp_error(conn, name, args) do
    assert %{"isError" => true, "content" => [%{"text" => text}]} = mcp(conn, name, args)
    text
  end

  describe "REST" do
    test "pause a pool, see it everywhere, resume it from the CLI", ctx do
      conn = with_token(ctx.user, "laptop", @cli)

      body =
        conn
        |> post(~p"/api/boards/#{ctx.board.code}/pause", %{
          "pool" => "dev",
          "reason" => "bad deploy"
        })
        |> json_response(201)

      assert %{"pool" => "dev", "reason" => "bad deploy", "line" => "paused by David: bad deploy"} =
               body["pause"]

      assert [%{"pool" => "dev"}] =
               conn
               |> get(~p"/api/boards/#{ctx.board.code}/pause")
               |> json_response(200)
               |> Map.fetch!("pauses")

      assert [%{"scope" => "pool dev"}] =
               conn
               |> get(~p"/api/boards/#{ctx.board.code}")
               |> json_response(200)
               |> Map.fetch!("paused")

      assert [%{"by" => "David"}] =
               conn
               |> get(~p"/api/boards/#{ctx.board.code}/cards")
               |> json_response(200)
               |> Map.fetch!("paused")

      # A session's claim says why there is nothing.
      claim =
        conn
        |> post(~p"/api/boards/#{ctx.board.code}/jobs/claim", %{"pool" => "dev"})
        |> json_response(200)

      assert claim["job"] == nil
      assert claim["held"] == "paused by David: bad deploy"
      assert claim["paused"]["pool"] == "dev"

      assert %{"pause" => %{"pool" => "dev", "resumed_at" => at}} =
               conn
               |> delete(~p"/api/boards/#{ctx.board.code}/pause?pool=dev")
               |> json_response(200)

      assert at

      refute Map.has_key?(
               conn |> get(~p"/api/boards/#{ctx.board.code}") |> json_response(200),
               "paused"
             )

      refute Map.has_key?(
               conn |> get(~p"/api/boards/#{ctx.board.code}/cards") |> json_response(200),
               "paused"
             )
    end

    test "the runner protocol's empty claim says why, in X-Held", ctx do
      {:ok, _} = Runners.pause(ctx.board, %{"reason" => "freeze"}, ctx.user)

      {:ok, _} =
        Runners.queue(card_fixture(ctx.todo), %{pool: "dev", kind: "claude", prompt: "go"})

      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer " <> ctx.runner_token)
        |> put_req_header("content-type", "text/plain")
        |> post("/api/runner/claim?wait=0")

      assert conn.status == 204
      assert get_resp_header(conn, "x-held") == ["paused by David: freeze"]
    end

    test "a pause needs a reason", ctx do
      conn = with_token(ctx.user, "laptop", @cli)

      assert %{"details" => %{"reason" => [_]}} =
               conn
               |> post(~p"/api/boards/#{ctx.board.code}/pause", %{"pool" => "dev"})
               |> json_response(422)

      assert Runners.pauses(ctx.board) == []
    end

    test "pausing twice is a conflict", ctx do
      conn = with_token(ctx.user, "laptop", @cli)
      post(conn, ~p"/api/boards/#{ctx.board.code}/pause", %{"reason" => "one"})

      assert %{"error" => "the whole tree is already paused" <> _} =
               conn
               |> post(~p"/api/boards/#{ctx.board.code}/pause", %{"reason" => "two"})
               |> json_response(409)
    end

    test "only a person resumes: no CLI header, or the agent header, is refused", ctx do
      {:ok, _} = Runners.pause(ctx.board, %{"pool" => "dev", "reason" => "bad deploy"}, ctx.user)

      for headers <- [
            [],
            @cli ++ [{"x-slipdock-agent", "1"}],
            @cli ++ [{"x-slipdock-agent", "1"}, {"x-slipdock-job", "7"}]
          ] do
        assert %{"error" => "forbidden: only a person can resume" <> _} =
                 ctx.user
                 |> with_token("bot", headers)
                 |> delete(~p"/api/boards/#{ctx.board.code}/pause?pool=dev")
                 |> json_response(403)
      end

      assert [_] = Runners.pauses(ctx.board)
    end

    test "someone the board is shared with can't pause it", ctx do
      editor = user_fixture("editor#{System.unique_integer([:positive])}@example.com")
      share_fixture(ctx.board, [editor], "write")

      editor
      |> with_token("theirs", @cli)
      |> post(~p"/api/boards/#{ctx.board.code}/pause", %{"reason" => "mine now"})
      |> json_response(403)

      assert Runners.pauses(ctx.board) == []
    end
  end

  describe "MCP" do
    test "manage_automation pause; get_board and list_cards carry paused; resume is refused",
         ctx do
      conn = with_token(ctx.user, "claude laptop")

      assert %{"pause" => %{"line" => "paused by David (claude laptop): tests red"}} =
               mcp_json(conn, "manage_automation", %{
                 "action" => "pause",
                 "board" => ctx.board.code,
                 "pool" => "dev",
                 "reason" => "tests red"
               })

      assert [%{"pool" => "dev", "reason" => "tests red"}] =
               mcp_json(conn, "get_board", %{"board" => ctx.board.code})["paused"]

      assert [%{"pool" => "dev"}] =
               mcp_json(conn, "list_cards", %{"board" => ctx.board.code})["paused"]

      assert %{"content" => [%{"text" => text}]} =
               mcp(conn, "claim_job", %{"board" => ctx.board.code, "pool" => "dev"})

      assert Jason.decode!(text) ==
               "nothing queued to take: paused by David (claude laptop): tests red"

      assert mcp_error(conn, "manage_automation", %{
               "action" => "resume",
               "board" => ctx.board.code,
               "pool" => "dev"
             }) =~ "only a person can resume"

      assert [_] = Runners.pauses(ctx.board)
    end

    test "get_board and list_cards leave paused out when nothing is", ctx do
      conn = with_token(ctx.user, "claude laptop")
      refute Map.has_key?(mcp_json(conn, "get_board", %{"board" => ctx.board.code}), "paused")
      refute Map.has_key?(mcp_json(conn, "list_cards", %{"board" => ctx.board.code}), "paused")
    end

    test "a pause without a reason, or by someone who doesn't own the board, is refused", ctx do
      conn = with_token(ctx.user, "claude laptop")

      assert mcp_error(conn, "manage_automation", %{
               "action" => "pause",
               "board" => ctx.board.code
             }) =~
               "reason"

      editor = user_fixture("editor#{System.unique_integer([:positive])}@example.com")
      share_fixture(ctx.board, [editor], "write")

      assert mcp_error(with_token(editor, "theirs"), "manage_automation", %{
               "action" => "pause",
               "board" => ctx.board.code,
               "reason" => "mine now"
             }) =~ "owner"

      assert Runners.pauses(ctx.board) == []
    end
  end
end
