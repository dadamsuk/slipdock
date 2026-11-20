defmodule SlipdockWeb.QuarantineClaimTest do
  @moduledoc """
  An `anyone`-tier job claimed in JSON (#3531): REST `POST
  /api/boards/:board/jobs/claim` (`slipdock claim-job`) and MCP `claim_job`
  answer the quarantined prompt, and the wait and handoff beside it as ids
  alone, never their text or the card's title. An owner's job still gets
  them in full.
  """
  use SlipdockWeb.ConnCase, async: true

  import Ecto.Query
  import Slipdock.Fixtures

  alias Slipdock.{Accounts, Actor, AIStub, Boards, Repo, Runners}
  alias Slipdock.Boards.{Card, Wait}

  @asked "The export button saves the board as CSV."
  @secrets ["Outsider title", "SECRET-NEEDS", "SECRET-ANSWER", "SECRET-NEXT", "SECRET-BODY"]

  setup %{user: user} do
    board = board_fixture(%{"name" => "Quarantined claims"}, owner: user)
    [_backlog, todo, _doing, _done] = board.columns
    %{user: user, board: board, todo: todo}
  end

  defp conn_for(user) do
    {token, _} = Accounts.create_api_token(user, "claims")

    build_conn()
    |> put_req_header("accept", "application/json")
    |> put_req_header("authorization", "Bearer " <> token)
  end

  # A card whose text an outsider wrote (`anyone`), with an answered wait its
  # job carries on from and a handoff, all text an agent mustn't see.
  defp anyone_job(ctx, outsider? \\ true) do
    card = card_fixture(ctx.todo, %{"title" => "Outsider title", "description" => @asked})
    by = if outsider?, do: [0], else: [ctx.user.id]
    Repo.update_all(from(c in Card, where: c.id == ^card.id), set: [text_by: by])
    card = Repo.reload!(card)

    {:ok, wait} = Boards.Waits.open_wait(card, Actor.web(ctx.user), %{needs: "SECRET-NEEDS"})

    {:ok, _} =
      Boards.Waits.answer_wait(Repo.reload!(card), Actor.web(ctx.user), %{
        "answer" => "SECRET-ANSWER"
      })

    {:ok, handoff} =
      Boards.Handoffs.leave_handoff(Repo.reload!(card), ctx.user, %{
        next_step: "SECRET-NEXT",
        body: "SECRET-BODY",
        via: "ui"
      })

    {:ok, job} = Runners.queue(Repo.reload!(card), %{pool: "dev", kind: "claude", prompt: "go"})
    Repo.update_all(from(w in Wait, where: w.id == ^wait.id), set: [requeue_job_id: job.id])

    AIStub.reply_with(%{
      "requirement" => @asked,
      "files" => [],
      "expected_behaviour" => [],
      "acceptance" => [],
      "context" => [],
      "open_questions" => [],
      "agent_directed" => false
    })

    %{job: job, wait: wait, handoff: handoff}
  end

  defp mcp_claim(conn, board) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post(
      "/mcp",
      Jason.encode!(%{
        jsonrpc: "2.0",
        id: 1,
        method: "tools/call",
        params: %{name: "claim_job", arguments: %{"board" => board.code, "pool" => "dev"}}
      })
    )
    |> json_response(200)
    |> get_in(["result", "content", Access.at(0), "text"])
  end

  defp refute_secrets(text) do
    for secret <- @secrets, do: refute(text =~ secret, "#{secret} leaked")
  end

  test "REST's JSON claim gives an anyone job's wait and handoff as ids alone", ctx do
    %{job: job, wait: wait, handoff: handoff} = anyone_job(ctx)

    body =
      ctx.user
      |> conn_for()
      |> post(~p"/api/boards/#{ctx.board.code}/jobs/claim", %{"pool" => "dev"})
      |> response(200)

    refute_secrets(body)
    claim = Jason.decode!(body)
    assert claim["job"]["id"] == job.id
    assert claim["job"]["card"] == nil
    assert claim["job"]["prompt"] =~ "> " <> @asked
    assert claim["wait"] == %{"id" => wait.id}
    assert claim["handoff"] == %{"id" => handoff.id}
  end

  test "MCP claim_job gives an anyone job's wait and handoff as ids alone", ctx do
    %{job: job, wait: wait, handoff: handoff} = anyone_job(ctx)

    text = mcp_claim(conn_for(ctx.user), ctx.board)

    refute_secrets(text)
    claim = Jason.decode!(text)
    assert claim["job"] == job.id
    assert claim["prompt"] =~ "> " <> @asked
    assert claim["wait"] == %{"id" => wait.id}
    assert claim["handoff"] == %{"id" => handoff.id}
  end

  test "an owner's job still gets the wait and handoff in full", ctx do
    anyone_job(ctx, false)

    claim =
      ctx.user
      |> conn_for()
      |> post(~p"/api/boards/#{ctx.board.code}/jobs/claim", %{"pool" => "dev"})
      |> json_response(200)

    assert claim["job"]["card"] == "Outsider title"
    assert claim["wait"]["answer"] == "SECRET-ANSWER"
    assert claim["handoff"]["body"] == "SECRET-BODY"
    refute_received {:ai_request, _}
  end
end
