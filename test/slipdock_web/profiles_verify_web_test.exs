defmodule SlipdockWeb.ProfilesVerifyWebTest do
  @moduledoc """
  The verifier's spend (#1953) at the web doors: a claimed job carries its
  card's profile at every claim (the runner's `x-card-profile` header, the
  REST session claim's `job.profile`, MCP `claim_job` `profile`), and none
  with profiles off; the ledger's REST line and page say "not verified
  (docs)" for a docs card the server accepted; `verify_card` takes a
  defect review's findings.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Accounts, Actor, Boards, Repo, Runners}
  alias Slipdock.Boards.Card

  setup %{user: user} do
    board = board_fixture(%{"name" => "Spend web", "code" => unique_code()}, owner: user)
    {:ok, board} = Boards.update_board(board, %{"profiles" => true})
    [_backlog, todo, doing, _done] = board.columns
    card = card_fixture(todo, %{"title" => "Migrate"})
    {:ok, card} = Boards.update_card(card, %{"profile" => "schema"})

    {:ok, _runner, runner_token} =
      Runners.create_runner(board, %{"name" => "box", "pool" => "dev"})

    %{board: board, doing: doing, card: card, runner_token: runner_token}
  end

  defp with_token(user) do
    {token, _} = Accounts.create_api_token(user, "laptop")

    build_conn()
    |> put_req_header("accept", "application/json")
    |> put_req_header("authorization", "Bearer " <> token)
  end

  defp mcp(conn, name, args) do
    %{"result" => %{"content" => [%{"text" => text}]}} =
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

    text
  end

  defp queue(card), do: Runners.queue(card, %{pool: "dev", kind: "work", prompt: "go"})

  defp runner_claim(ctx) do
    build_conn()
    |> put_req_header("authorization", "Bearer " <> ctx.runner_token)
    |> post("/api/runner/claim?wait=0")
  end

  defp profiles_off(ctx),
    do:
      {:ok, _} =
        Boards.update_board(Repo.get!(Boards.Board, ctx.board.id), %{"profiles" => false})

  describe "a claimed job's profile" do
    test "the runner's claim says it as a header", ctx do
      {:ok, _} = queue(ctx.card)
      conn = runner_claim(ctx)
      assert conn.status == 200
      assert get_resp_header(conn, "x-card-profile") == ["schema"]
    end

    test "with profiles off the header is left out", ctx do
      profiles_off(ctx)
      {:ok, _} = queue(ctx.card)
      conn = runner_claim(ctx)
      assert conn.status == 200
      assert get_resp_header(conn, "x-card-profile") == []
    end

    test "the REST session claim carries job.profile", ctx do
      {:ok, _} = queue(ctx.card)

      claim =
        ctx.user
        |> with_token()
        |> post(~p"/api/boards/#{ctx.board.code}/jobs/claim", %{"pool" => "dev"})
        |> json_response(200)

      assert claim["job"]["profile"] == "schema"
    end

    test "MCP claim_job carries profile, null with profiles off", ctx do
      {:ok, _} = queue(ctx.card)

      text =
        ctx.user
        |> with_token()
        |> mcp("claim_job", %{"board" => ctx.board.code, "pool" => "dev"})

      assert Jason.decode!(text)["profile"] == "schema"

      profiles_off(ctx)
      other = card_fixture(hd(tl(ctx.board.columns)), %{"title" => "Next"})
      {:ok, _} = queue(other)

      text =
        ctx.user
        |> with_token()
        |> mcp("claim_job", %{"board" => ctx.board.code, "pool" => "dev"})

      assert Jason.decode!(text)["profile"] == nil
    end
  end

  describe "a docs card accepted unverified" do
    setup ctx do
      {:ok, board} =
        Boards.update_board(ctx.board, %{"verify_work" => true, "verify_pool" => "checkers"})

      docs = card_fixture(ctx.doing, %{"title" => "Guide"})
      {:ok, docs} = Boards.update_card(docs, %{"profile" => "docs"})

      builder = %{
        Actor.unknown()
        | kind: "agent",
          via: "api",
          user_id: ctx.user.id,
          agent: "builder"
      }

      {:ok, _} =
        Boards.update_card(
          docs,
          %{
            "completed" => true,
            "evidence" => "Rewrote it",
            "evidence_suite" => %{"result" => "passed", "passed" => 3, "failed" => 0}
          },
          actor: builder
        )

      %{board: board, docs: Repo.get!(Card, docs.id)}
    end

    test "the REST ledger line says not_verified docs and no acceptor", ctx do
      assert ctx.docs.verify_state == "accepted"

      body =
        ctx.user
        |> with_token()
        |> get(~p"/api/boards/#{ctx.board.code}/ledger?since=1")
        |> json_response(200)

      item =
        body["days"]
        |> Enum.flat_map(& &1["items"])
        |> Enum.find(&(&1["card"]["id"] == ctx.docs.id))

      assert item["not_verified"] == "docs"
      assert item["accepted_by"] == nil
    end

    test "the Ledger page reads not verified (docs)", %{conn: conn} = ctx do
      {:ok, view, _html} = live(conn, ~p"/boards/#{ctx.board.id}/ledger")
      assert view |> element("[data-role=acceptor]") |> render() =~ "not verified (docs)"
    end
  end

  test "MCP verify_card takes a defect review, and refuses an acceptance with an important one",
       ctx do
    {:ok, _} = Boards.update_board(ctx.board, %{"verify_work" => true})
    card = card_fixture(ctx.doing, %{"title" => "Auth"})
    {:ok, card} = Boards.update_card(card, %{"profile" => "security"})
    builder = %{Actor.unknown() | kind: "agent", via: "api", user_id: ctx.user.id, agent: "b"}
    {:ok, _} = Boards.update_card(card, %{"completed" => true}, actor: builder)

    text =
      ctx.user
      |> with_token()
      |> mcp("verify_card", %{
        "card" => card.id,
        "decision" => "accept",
        "checks" => ["ask=ok", "defect:important=lib/auth.ex:9:no check"]
      })

    assert text =~ "the defect at lib/auth.ex:9"
    assert Repo.get!(Card, card.id).verify_state == "pending"

    ctx.user
    |> with_token()
    |> mcp("verify_card", %{
      "card" => card.id,
      "decision" => "accept",
      "reason" => "Checked",
      "checks" => ["ask=ok", "defect:nit=lib/auth.ex:3"]
    })

    assert [%{"severity" => "nit", "line" => 3}] =
             Repo.get!(Card, card.id).verify_checks["defect_review"]
  end
end
