defmodule SlipdockWeb.WorkDismissAPITest do
  @moduledoc """
  Taking things off one's own Waiting on you over REST and MCP (#2069):
  dismiss an item (held on its cause), list and undo dismissals, mute and
  unmute a board's tree, and the counts beside the list.
  """
  use SlipdockWeb.ConnCase, async: true

  import Ecto.Query
  import Slipdock.Fixtures

  alias Slipdock.{Accounts, Actor, Boards, Repo, Runners, Work}
  alias Slipdock.Runners.Job

  setup %{user: user} do
    board = board_fixture(%{"name" => "Ops"}, owner: user)
    [_backlog, todo, _doing, _done] = board.columns
    dana = user_fixture("dana@example.com")
    {:ok, _} = Slipdock.Access.grant(board, dana, "write", user)
    asker = %{Actor.unknown() | kind: "agent", via: "mcp", user_id: dana.id}
    %{board: board, todo: todo, dana: dana, asker: asker}
  end

  defp with_token(user, opts \\ []) do
    {token, _} = Accounts.create_api_token(user, "laptop", opts)

    build_conn()
    |> put_req_header("accept", "application/json")
    |> put_req_header("authorization", "Bearer " <> token)
  end

  defp failed_job(card) do
    {:ok, job} = Runners.queue(card, %{pool: "dev", kind: "claude", prompt: "go"})
    from(j in Job, where: j.id == ^job.id) |> Repo.update_all(set: [status: "failed"])
    Repo.get!(Job, job.id)
  end

  defp wait_anyone(ctx, card) do
    {:ok, wait} = Boards.open_wait(card, ctx.asker, %{"needs" => "Which region?"})
    wait
  end

  defp mcp_call(conn, name, args) do
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

  defp mcp_json(result) do
    %{"content" => [%{"text" => text}]} = result
    Jason.decode!(text)
  end

  defp waiting_ids(conn),
    do:
      conn
      |> get("/api/work")
      |> json_response(200)
      |> Map.fetch!("waiting")
      |> Enum.map(& &1["card"]["id"])

  describe "REST" do
    test "dismiss, list, undo; the counts say what is hidden", ctx do
      card = card_fixture(ctx.todo, %{"title" => "Flaky"})
      job = failed_job(card)
      kept = card_fixture(ctx.todo, %{"title" => "Kept"})
      wait_anyone(ctx, kept)
      conn = with_token(ctx.user)

      body = conn |> get("/api/work") |> json_response(200)
      assert body["waiting_count"] == 2
      assert body["dismissed_count"] == 0
      assert body["muted_count"] == 0
      assert body["muted_boards"] == []

      assert Enum.find(body["waiting"], &(&1["card"]["id"] == card.id))["cause"] ==
               "job:#{job.id}"

      d = conn |> post("/api/work/dismissed", %{card: "##{card.id}"}) |> json_response(200)
      assert d["dismissed"]["card"]["id"] == card.id
      assert d["dismissed"]["cause"] == "job:#{job.id}"

      body = conn |> get("/api/work") |> json_response(200)
      assert Enum.map(body["waiting"], & &1["card"]["id"]) == [kept.id]
      assert body["waiting_count"] == 1
      assert body["dismissed_count"] == 1
      assert (conn |> get("/api/me") |> json_response(200))["waiting_on_you"] == 1

      list = conn |> get("/api/work/dismissed") |> json_response(200)
      assert [%{"card" => %{"id" => id}, "path" => ["Ops"]}] = list["dismissed"]
      assert id == card.id

      # Off the list already, it can't be dismissed again.
      assert conn |> post("/api/work/dismissed", %{card: card.id}) |> json_response(422)

      undo = conn |> delete("/api/work/dismissed/#{card.id}") |> json_response(200)
      assert undo["undismissed"] == %{"card_id" => card.id, "count" => 1}
      assert Enum.sort(waiting_ids(conn)) == Enum.sort([card.id, kept.id])
      assert conn |> delete("/api/work/dismissed/#{card.id}") |> json_response(404)
    end

    test "a second failed job brings the card back", ctx do
      card = card_fixture(ctx.todo)
      failed_job(card)
      conn = with_token(ctx.user)
      conn |> post("/api/work/dismissed", %{card: card.id}) |> json_response(200)
      assert waiting_ids(conn) == []

      failed_job(card)
      assert waiting_ids(conn) == [card.id]
    end

    test "my dismissal leaves Dana's list alone", ctx do
      card = card_fixture(ctx.todo, %{"assignee_ids" => [ctx.dana.id]})
      wait_anyone(ctx, card)
      mine = with_token(ctx.user)
      hers = with_token(ctx.dana)

      assert waiting_ids(hers) == [card.id]
      mine |> post("/api/work/dismissed", %{card: card.id}) |> json_response(200)
      assert waiting_ids(mine) == []
      assert waiting_ids(hers) == [card.id]
    end

    test "a card not waiting, one I can't read, and a read-only token are refused", ctx do
      quiet = card_fixture(ctx.todo)
      conn = with_token(ctx.user)

      assert %{"error" => error} =
               conn |> post("/api/work/dismissed", %{card: quiet.id}) |> json_response(422)

      assert error =~ "isn't waiting on you"

      stranger = user_fixture("stranger@example.com")

      assert stranger
             |> with_token()
             |> post("/api/work/dismissed", %{card: quiet.id})
             |> json_response(403)

      assert ctx.user
             |> with_token(scope: "read")
             |> post("/api/work/dismissed", %{card: quiet.id})
             |> json_response(403)
    end

    test "mute and unmute a board's tree", ctx do
      parent = card_fixture(ctx.todo, %{"title" => "Epic"})
      {:ok, t} = Boards.find_template(nil, "Simple")
      {:ok, sub} = sub_board(parent, t)
      deep = card_fixture(hd(Boards.get_board!(sub.id).columns))
      failed_job(deep)
      conn = with_token(ctx.user)
      assert waiting_ids(conn) == [deep.id]

      m = conn |> post("/api/work/muted", %{board: ctx.board.id}) |> json_response(200)
      assert m["muted"]["id"] == ctx.board.id

      body = conn |> get("/api/work") |> json_response(200)
      assert body["waiting"] == []
      assert body["muted_count"] == 1
      assert [%{"id" => id, "name" => "Ops"}] = body["muted_boards"]
      assert id == ctx.board.id

      # Dana, who could see the board too, is unaffected; so is the board itself.
      assert Work.muted_by(ctx.dana, ctx.board) == nil

      assert conn |> delete("/api/work/muted/#{ctx.board.id}") |> json_response(200)
      assert waiting_ids(conn) == [deep.id]
      assert conn |> delete("/api/work/muted/#{ctx.board.id}") |> json_response(404)
      assert conn |> post("/api/work/muted", %{board: "nowhere-at-all"}) |> json_response(404)
    end
  end

  describe "MCP" do
    test "update_card waiting_list: dismiss and undismiss; whoami counts them", ctx do
      card = card_fixture(ctx.todo)
      failed_job(card)
      conn = with_token(ctx.user)

      r = conn |> mcp_call("update_card", %{card: card.id, waiting_list: "dismiss"}) |> mcp_json()
      assert r["dismissed"]["card"]["id"] == card.id
      assert Work.waiting_on_me(ctx.user) == []

      who = conn |> mcp_call("whoami", %{}) |> mcp_json()
      assert who["waiting_on_you"] == 0
      assert who["waiting_hidden"] == %{"dismissed" => 1, "muted" => 0, "muted_boards" => 0}

      r =
        conn |> mcp_call("update_card", %{card: card.id, waiting_list: "undismiss"}) |> mcp_json()

      assert r["undismissed"]["count"] == 1
      assert [_] = Work.waiting_on_me(ctx.user)

      # Not on the list: said plainly, as an error.
      quiet = card_fixture(ctx.todo)

      assert %{"isError" => true} =
               mcp_call(conn, "update_card", %{id: quiet.id, waiting_list: "dismiss"})
    end

    test "a reader can dismiss from their own list without edit rights", ctx do
      reader = user_fixture("reader@example.com")
      {:ok, _} = Slipdock.Access.grant(ctx.board, reader, "read", ctx.user)
      card = card_fixture(ctx.todo)
      {:ok, _} = Boards.open_wait(card, ctx.asker, %{"needs" => "Ok?", "on_user_id" => reader.id})
      assert [_] = Work.waiting_on_me(reader)

      r =
        reader
        |> with_token()
        |> mcp_call("update_card", %{card: card.id, waiting_list: "dismiss"})
        |> mcp_json()

      assert r["dismissed"]["card"]["id"] == card.id
      assert Work.waiting_on_me(reader) == []
      # Still the card it was: nothing written to it.
      assert Boards.get_card!(card.id).updated_at == card.updated_at
    end

    test "update_board waiting_list: mute and unmute", ctx do
      card = card_fixture(ctx.todo)
      failed_job(card)
      conn = with_token(ctx.user)

      r =
        conn
        |> mcp_call("update_board", %{board: ctx.board.id, waiting_list: "mute"})
        |> mcp_json()

      assert r["muted"]["id"] == ctx.board.id
      assert Work.waiting_on_me(ctx.user) == []

      assert (conn |> mcp_call("whoami", %{}) |> mcp_json())["waiting_hidden"]["muted_boards"] ==
               1

      r =
        conn
        |> mcp_call("update_board", %{board: ctx.board.id, waiting_list: "unmute"})
        |> mcp_json()

      assert r["unmuted"]["id"] == ctx.board.id
      assert [_] = Work.waiting_on_me(ctx.user)
    end
  end
end
