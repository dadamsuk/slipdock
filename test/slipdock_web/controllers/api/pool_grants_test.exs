defmodule SlipdockWeb.API.PoolGrantsTest do
  @moduledoc """
  The doors to a pool's jobs over HTTP and MCP (#3492): the API's claim
  (which `slipdock claim-job` sends) and MCP `claim_job` refuse a writer
  the owner hasn't granted the pool, saying why, and serve the owner and a
  granted writer; and `/api/boards/:board/pool-grants`, where the owner
  lists, grants and takes back. The rules themselves are in
  `test/slipdock/runners/pool_grants_test.exs`.
  """
  use SlipdockWeb.ConnCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Access, Accounts, Actor, Runners}
  alias Slipdock.Runners.PoolGrants

  setup %{conn: conn, user: owner} do
    board = board_fixture(%{"name" => "Pool doors"}, owner: owner)
    card = card_fixture(hd(board.columns), %{"title" => "Work"})
    writer = user_fixture("writer-#{System.unique_integer([:positive])}@example.com")
    {:ok, _} = Access.grant(board, writer, "write", owner)
    {token, _} = Accounts.create_api_token(writer, "desk")

    writer_conn =
      build_conn()
      |> put_req_header("accept", "application/json")
      |> put_req_header("authorization", "Bearer " <> token)

    %{
      conn: put_req_header(conn, "accept", "application/json"),
      writer_conn: writer_conn,
      writer: writer,
      board: board,
      card: card
    }
  end

  defp queue(ctx), do: Runners.queue(ctx.card, %{pool: "dev", kind: "claude", prompt: "Do"})

  defp grant!(ctx),
    do:
      {:ok, _} =
        PoolGrants.grant(ctx.board, "dev", ctx.writer.email, actor: Actor.web(ctx.user))

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

  describe "POST /api/boards/:board/jobs/claim" do
    test "a writer with no grant for the pool is refused with a reason", ctx do
      {:ok, job} = queue(ctx)

      body =
        ctx.writer_conn
        |> post("/api/boards/#{ctx.board.id}/jobs/claim", %{pool: "dev"})
        |> json_response(403)

      assert body["error"] =~ "forbidden: taking the pool “dev”'s jobs needs the board's owner"
      assert Slipdock.Repo.get!(Runners.Job, job.id).status == "queued"
    end

    test "a granted writer takes the job; so does the owner", ctx do
      {:ok, job} = queue(ctx)
      grant!(ctx)

      body =
        ctx.writer_conn
        |> post("/api/boards/#{ctx.board.id}/jobs/claim", %{pool: "dev"})
        |> json_response(200)

      assert body["job"]["id"] == job.id

      {:ok, job2} = queue(ctx)

      body =
        ctx.conn
        |> post("/api/boards/#{ctx.board.id}/jobs/claim", %{pool: "dev"})
        |> json_response(200)

      assert body["job"]["id"] == job2.id
    end
  end

  describe "MCP claim_job" do
    test "a writer with no grant is refused with a reason", ctx do
      {:ok, _job} = queue(ctx)
      result = mcp(ctx.writer_conn, "claim_job", %{board: ctx.board.code, pool: "dev"})

      assert result["isError"] == true
      [%{"text" => text}] = result["content"]
      assert text =~ "taking the pool “dev”'s jobs needs the board's owner"
    end

    test "a granted writer takes the job", ctx do
      {:ok, job} = queue(ctx)
      grant!(ctx)
      result = mcp(ctx.writer_conn, "claim_job", %{board: ctx.board.code, pool: "dev"})

      assert result["isError"] == false, inspect(result["content"])
      [%{"text" => text}] = result["content"]
      assert text =~ ~s("job":#{job.id})
    end
  end

  describe "/api/boards/:board/pool-grants" do
    test "the owner grants, lists and takes back", ctx do
      path = "/api/boards/#{ctx.board.id}/pool-grants"

      created =
        ctx.conn
        |> post(path, %{pool: "Dev", email: ctx.writer.email})
        |> json_response(201)

      assert created["pool_grant"]["pool"] == "dev"
      assert created["pool_grant"]["user"]["email"] == ctx.writer.email
      assert created["pool_grant"]["granted_by"] == ctx.user.email

      assert [%{"pool" => "dev"}] =
               ctx.conn |> get(path) |> json_response(200) |> Map.fetch!("pool_grants")

      assert [] =
               ctx.conn
               |> get(path, pool: "verify")
               |> json_response(200)
               |> Map.fetch!("pool_grants")

      assert %{"revoked" => %{"pool" => "dev"}} =
               ctx.conn
               |> delete(path, pool: "dev", email: ctx.writer.email)
               |> json_response(200)

      assert ctx.conn |> delete(path, pool: "dev", email: ctx.writer.email) |> json_response(404)
      refute PoolGrants.may_take?(ctx.writer, ctx.board, "dev")
    end

    test "a writer can't grant themself, or anybody, a pool", ctx do
      path = "/api/boards/#{ctx.board.id}/pool-grants"

      ctx.writer_conn |> post(path, %{pool: "dev", email: ctx.writer.email}) |> json_response(403)
      ctx.writer_conn |> get(path) |> json_response(403)
      refute PoolGrants.may_take?(ctx.writer, ctx.board, "dev")
    end

    test "a person who can't write the board isn't granted, and says why", ctx do
      body =
        ctx.conn
        |> post("/api/boards/#{ctx.board.id}/pool-grants", %{
          pool: "dev",
          email: fixture_email("nobody@example.com")
        })
        |> json_response(422)

      assert body["error"] =~ "share it with them first"

      assert ctx.conn
             |> post("/api/boards/#{ctx.board.id}/pool-grants", %{pool: "dev"})
             |> json_response(422)
    end
  end
end
