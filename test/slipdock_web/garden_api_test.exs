defmodule SlipdockWeb.GardenAPITest do
  @moduledoc """
  The board gardener over HTTP and MCP (W-1807): a run started and listed,
  suggestions applied, dismissed and undone, settings changed, and every
  write refused to a reader, a read-only token and a stranger.
  """
  use SlipdockWeb.ConnCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Access, Accounts, Boards, Gardener}

  setup %{user: owner} do
    board = board_fixture(%{}, owner: owner)
    [_backlog, _todo, doing, done] = board.columns
    # complete outside Done: completed_not_done finds it
    stray = card_fixture(doing, %{"title" => "Stray", "completed" => true})
    reader = user_fixture("garden-reader@example.com")
    {:ok, _} = Access.grant(board, reader, "read", owner)
    stranger = user_fixture("garden-stranger@example.com")
    %{board: board, owner: owner, reader: reader, stranger: stranger, stray: stray, done: done}
  end

  defp as(user), do: user |> conn_as() |> put_req_header("accept", "application/json")

  defp with_token(user, opts) do
    {token, _} = Accounts.create_api_token(user, "limited", opts)

    build_conn()
    |> put_req_header("accept", "application/json")
    |> put_req_header("authorization", "Bearer " <> token)
  end

  defp open_one(board) do
    {:ok, _} = Gardener.run(board, only: ["completed_not_done"])
    [s] = Gardener.list_open(board)
    s
  end

  describe "GET and POST /api/boards/:board/garden" do
    test "a run, then the open suggestions with their subjects named", ctx do
      assert %{"suggestions" => [], "last_run" => nil, "checks" => checks} =
               as(ctx.owner) |> get("/api/boards/#{ctx.board.code}/garden") |> json_response(200)

      assert %{"key" => "abandoned_backlog", "enabled" => false, "settings" => %{"days" => 180}} =
               Enum.find(checks, &(&1["key"] == "abandoned_backlog"))

      assert %{"suggestions" => [s], "last_run" => run} =
               as(ctx.owner)
               |> post("/api/boards/#{ctx.board.code}/garden", %{})
               |> json_response(200)

      assert run["trigger"] == "manual"
      assert run["counts"]["completed_not_done"] == 1
      assert s["check"] == "completed_not_done"
      assert s["label"] == "Complete but not in Done"

      assert s["cards"] == [
               %{"id" => ctx.stray.id, "title" => "Stray", "board_id" => ctx.board.id}
             ]

      assert [%{"op" => "move", "column" => col}] = s["proposal"]
      assert col == ctx.done.id
      assert s["needs_keep"] == false

      # A reader can list what is there.
      assert %{"suggestions" => [_]} =
               as(ctx.reader) |> get("/api/boards/#{ctx.board.code}/garden") |> json_response(200)
    end

    test "check narrows the run and the list; an unknown one is refused", ctx do
      assert %{"suggestions" => []} =
               as(ctx.owner)
               |> post("/api/boards/#{ctx.board.code}/garden", %{"check" => "epic_done"})
               |> json_response(200)

      assert %{"error" => error} =
               as(ctx.owner)
               |> get("/api/boards/#{ctx.board.code}/garden?check=tidy")
               |> json_response(400)

      assert error =~ "unknown check \"tidy\": one of epic_done"
    end

    test "running needs write access", ctx do
      assert as(ctx.reader)
             |> post("/api/boards/#{ctx.board.code}/garden", %{})
             |> json_response(403)

      assert with_token(ctx.owner, scope: "read")
             |> post("/api/boards/#{ctx.board.code}/garden", %{})
             |> json_response(403)

      assert as(ctx.stranger) |> get("/api/boards/#{ctx.board.code}/garden") |> json_response(404)
    end
  end

  describe "deciding" do
    test "apply moves the card, undo puts it back", ctx do
      s = open_one(ctx.board)

      assert %{"suggestion" => %{"state" => "applied", "decided_by_id" => by}} =
               as(ctx.owner)
               |> post("/api/garden/suggestions/#{s.id}/apply", %{})
               |> json_response(200)

      assert by == ctx.owner.id
      assert Boards.get_card!(ctx.stray.id).column_id == ctx.done.id

      assert %{"suggestion" => %{"state" => "open"}} =
               as(ctx.owner)
               |> post("/api/garden/suggestions/#{s.id}/undo", %{})
               |> json_response(200)

      refute Boards.get_card!(ctx.stray.id).column_id == ctx.done.id
    end

    test "dismiss, then applying it is refused with the reason", ctx do
      s = open_one(ctx.board)

      assert %{"suggestion" => %{"state" => "dismissed"}} =
               as(ctx.owner)
               |> post("/api/garden/suggestions/#{s.id}/dismiss", %{})
               |> json_response(200)

      assert %{"error" => "that suggestion is dismissed, not open"} =
               as(ctx.owner)
               |> post("/api/garden/suggestions/#{s.id}/apply", %{})
               |> json_response(422)
    end

    test "an unknown field and an unknown suggestion are refused", ctx do
      s = open_one(ctx.board)

      assert %{"error" => "unknown field(s): survivor"} =
               as(ctx.owner)
               |> post("/api/garden/suggestions/#{s.id}/apply", %{"survivor" => 1})
               |> json_response(400)

      assert as(ctx.owner) |> post("/api/garden/suggestions/0/apply", %{}) |> json_response(404)
    end

    test "a reader, a read-only token and a stranger may not decide", ctx do
      s = open_one(ctx.board)

      for conn <- [as(ctx.reader), with_token(ctx.owner, scope: "read")],
          verb <- ~w(apply dismiss undo) do
        assert conn |> post("/api/garden/suggestions/#{s.id}/#{verb}", %{}) |> json_response(403)
      end

      assert as(ctx.stranger)
             |> post("/api/garden/suggestions/#{s.id}/apply", %{})
             |> response(404)

      assert Gardener.get_suggestion(s.id).state == "open"
    end
  end

  describe "PATCH /api/boards/:board/garden/settings" do
    test "changes one check's settings", ctx do
      assert %{"checks" => checks} =
               as(ctx.owner)
               |> patch("/api/boards/#{ctx.board.code}/garden/settings", %{
                 "check" => "stale_in_progress",
                 "days" => "21"
               })
               |> json_response(200)

      assert %{"settings" => %{"days" => 21}} =
               Enum.find(checks, &(&1["key"] == "stale_in_progress"))
    end

    test "a bad value, a missing check and a reader are refused", ctx do
      path = "/api/boards/#{ctx.board.code}/garden/settings"

      assert %{"error" => "days must be a whole number above 0"} =
               as(ctx.owner)
               |> patch(path, %{"check" => "long_overdue", "days" => "0"})
               |> json_response(422)

      assert %{"error" => "check is required" <> _} =
               as(ctx.owner) |> patch(path, %{}) |> json_response(400)

      assert as(ctx.reader)
             |> patch(path, %{"check" => "long_overdue", "days" => "9"})
             |> json_response(403)
    end
  end

  describe "MCP" do
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

    defp ok!(result) do
      assert result["isError"] == false, inspect(result["content"])
      result["structuredContent"]
    end

    defp error!(result) do
      assert result["isError"] == true
      [%{"text" => text}] = result["content"]
      text
    end

    test "garden lists without running, and runs with run: true", ctx do
      assert %{"suggestions" => [], "note" => "Nothing to tidy."} =
               as(ctx.owner) |> call("garden", %{board: ctx.board.code}) |> ok!()

      assert %{"suggestions" => [s], "last_run" => %{"trigger" => "mcp"}, "note" => note} =
               as(ctx.owner) |> call("garden", %{board: ctx.board.code, run: true}) |> ok!()

      assert s["check"] == "completed_not_done"
      assert note =~ "apply only what they approve"
    end

    test "a read-only token can list but not run", ctx do
      conn = with_token(ctx.owner, scope: "read")
      assert %{"suggestions" => []} = conn |> call("garden", %{board: ctx.board.code}) |> ok!()

      assert with_token(ctx.owner, scope: "read")
             |> call("garden", %{board: ctx.board.code, run: true})
             |> error!()
    end

    test "garden_decide without confirm is refused, and changes nothing", ctx do
      s = open_one(ctx.board)

      text =
        as(ctx.owner)
        |> call("garden_decide", %{suggestion: s.id, decision: "apply", confirm: false})
        |> error!()

      assert text =~ "needs confirm = true"
      assert Gardener.get_suggestion(s.id).state == "open"
    end

    test "garden_decide applies, undoes and dismisses", ctx do
      s = open_one(ctx.board)

      decide =
        &(as(ctx.owner)
          |> call("garden_decide", Map.merge(%{suggestion: s.id, confirm: true}, &1)))

      assert %{"suggestion" => %{"state" => "applied"}} = decide.(%{decision: "apply"}) |> ok!()
      assert %{"suggestion" => %{"state" => "open"}} = decide.(%{decision: "undo"}) |> ok!()

      assert %{"suggestion" => %{"state" => "dismissed"}} =
               decide.(%{decision: "dismiss"}) |> ok!()

      assert decide.(%{decision: "maybe"}) |> error!() =~
               "decision must be apply, dismiss or undo"
    end

    test "garden_decide is refused to a reader and a read-only token", ctx do
      s = open_one(ctx.board)
      args = %{suggestion: s.id, decision: "apply", confirm: true}

      assert as(ctx.reader) |> call("garden_decide", args) |> error!()

      assert with_token(ctx.owner, scope: "read") |> call("garden_decide", args) |> error!() =~
               "read-only"

      assert Gardener.get_suggestion(s.id).state == "open"
    end
  end
end
