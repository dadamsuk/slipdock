defmodule SlipdockWeb.MCP.WaitToolsTest do
  @moduledoc """
  Waiting on a person over MCP (#1114): `update_card` opens a wait with
  `wait`, withdraws it with `wait: null` and answers with `answer_wait`;
  `get_card` returns `wait` while it is open and `last_wait` after. A
  session runner's own job is linked without naming it, and the record is
  the same whichever door it came through.
  """
  use SlipdockWeb.ConnCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Access, Accounts, Boards, Repo, Runners}

  setup %{user: owner} do
    board = board_fixture(%{}, owner: owner)
    card = card_fixture(hd(board.columns), %{"title" => "Deploy"})

    dana =
      "dana@example.com"
      |> user_fixture()
      |> Ecto.Changeset.change(name: "Dana")
      |> Repo.update!()

    commenter = user_fixture("commenter@example.com")
    {:ok, _} = Access.grant(board, dana, "write", owner)
    {:ok, _} = Access.grant(board, commenter, "read", owner)
    {:ok, _} = Access.grant(card, commenter, "comment", owner)
    %{board: board, card: card, owner: owner, dana: dana, commenter: commenter}
  end

  defp with_token(user, label) do
    {token, api_token} = Accounts.create_api_token(user, label)

    {build_conn()
     |> put_req_header("accept", "application/json")
     |> put_req_header("authorization", "Bearer " <> token), api_token}
  end

  defp as(user, label \\ "claude"), do: user |> with_token(label) |> elem(0)

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

  defp open(conn, card, wait), do: call(conn, "update_card", %{card: card.id, wait: wait})

  test "update_card wait opens it; get_card shows wait, then last_wait once answered", ctx do
    assert %{"wait" => wait} =
             as(ctx.owner)
             |> open(ctx.card, %{
               needs: "Which region?",
               on: ctx.dana.email,
               choices: ["eu", "us"]
             })
             |> ok!()

    assert %{"kind" => "agent", "via" => "mcp", "agent" => "claude", "open" => true} = wait

    got = as(ctx.owner) |> call("get_card", %{card: ctx.card.id}) |> ok!()
    assert got["wait"]["needs"] == "Which region?"
    assert got["last_wait"] == nil
    assert "waiting" in got["flags"]

    assert %{"wait" => %{"close_reason" => "answered", "choice" => 2}} =
             as(ctx.dana)
             |> call("update_card", %{card: ctx.card.id, answer_wait: %{choice: 2}})
             |> ok!()

    got = as(ctx.owner) |> call("get_card", %{card: ctx.card.id}) |> ok!()
    assert got["wait"] == nil
    assert got["last_wait"]["choice_text"] == "us"
    refute "waiting" in got["flags"]
  end

  test "an agent can't answer the wait it opened on its own token", ctx do
    {conn, _} = with_token(ctx.owner, "claude")
    open(conn, ctx.card, %{needs: "Which region?"})

    assert conn
           |> call("update_card", %{card: ctx.card.id, answer_wait: %{answer: "eu"}})
           |> error!() =~ "an agent can't answer the wait it opened itself"
  end

  test "wait: null withdraws it; removing the flag withdraws it too (AE4)", ctx do
    open(as(ctx.owner), ctx.card, %{needs: "Which region?"})

    assert %{"wait" => %{"close_reason" => "withdrawn"}} =
             as(ctx.owner) |> call("update_card", %{card: ctx.card.id, wait: nil}) |> ok!()

    open(as(ctx.owner), ctx.card, %{needs: "Size?"})

    as(ctx.dana)
    |> call("update_card", %{card: ctx.card.id, remove_flags: ["waiting"]})
    |> ok!()

    assert %{close_reason: "withdrawn", needs: "Size?"} = Boards.last_wait(ctx.card)
  end

  test "bad shapes and both at once are refused", ctx do
    assert as(ctx.owner) |> open(ctx.card, "Which region?") |> error!() =~ "wait is an object"

    assert as(ctx.owner)
           |> call("update_card", %{
             card: ctx.card.id,
             wait: %{needs: "A"},
             answer_wait: %{answer: "B"}
           })
           |> error!() =~ "not both"

    assert as(ctx.owner) |> open(ctx.card, %{needs: " "}) |> error!() =~
             "needs can't be blank"
  end

  test "a commenter can open or answer none", ctx do
    assert as(ctx.commenter) |> open(ctx.card, %{needs: "Mine?"}) |> error!()
    open(as(ctx.owner), ctx.card, %{needs: "Which region?"})

    assert as(ctx.commenter)
           |> call("update_card", %{card: ctx.card.id, answer_wait: %{answer: "eu"}})
           |> error!()

    assert Boards.current_wait(ctx.card).needs == "Which region?"
  end

  describe "a session runner's job" do
    setup ctx do
      {conn, api_token} = with_token(ctx.owner, "desktop")
      {:ok, session} = Runners.session_runner(ctx.board, "dev", api_token, ctx.owner)
      {:ok, job} = Runners.queue(ctx.card, %{pool: "dev", kind: "claude", prompt: "do it"})
      %Runners.Job{} = Runners.claim(session)
      %{conn: conn, job: job}
    end

    test "is linked without being named", ctx do
      assert %{"wait" => %{"job_id" => job_id}} =
               open(ctx.conn, ctx.card, %{needs: "Which region?"}) |> ok!()

      assert job_id == ctx.job.id
    end

    test "is not linked on a card it isn't working", ctx do
      other = card_fixture(hd(ctx.board.columns))

      assert %{"wait" => %{"job_id" => nil}} =
               open(ctx.conn, other, %{needs: "Which region?"}) |> ok!()
    end

    test "another card's job named outright is refused, the job untouched", ctx do
      other = card_fixture(hd(ctx.board.columns))
      before = Repo.get!(Runners.Job, ctx.job.id)

      assert open(ctx.conn, other, %{needs: "Which region?", job_id: ctx.job.id}) |> error!() =~
               "is working on another card"

      assert Repo.get!(Runners.Job, ctx.job.id) == before
    end
  end

  test "REST and MCP make the same record from the same input", ctx do
    other = card_fixture(hd(ctx.board.columns))
    input = %{needs: "Which region?", on: ctx.dana.email, choices: ["eu", "us"]}

    %{"wait" => mcp} = as(ctx.owner, "same") |> open(ctx.card, input) |> ok!()

    %{"wait" => rest} =
      as(ctx.owner, "same")
      |> post("/api/cards/#{other.id}/wait", input)
      |> json_response(201)

    drop = ~w(id card_id via opened_at)
    assert Map.drop(mcp, drop) == Map.drop(rest, drop)
    assert {mcp["via"], rest["via"]} == {"mcp", "api"}
  end
end
