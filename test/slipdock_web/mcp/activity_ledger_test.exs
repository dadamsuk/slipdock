defmodule SlipdockWeb.MCP.ActivityLedgerTest do
  @moduledoc """
  The ledger over MCP (#1948): `activity` with `view: "ledger"` gives what
  `GET /api/boards/:board/ledger` gives, takes `since`, refuses a bad one and
  an unknown view as tool errors, keeps the log as the default view, and
  reads a stranger's board as no board.
  """
  use SlipdockWeb.ConnCase, async: true

  import Ecto.Query
  import Slipdock.Fixtures

  alias Slipdock.{Accounts, Repo}
  alias Slipdock.Boards.Card

  setup %{user: user} do
    board = board_fixture(%{"name" => "Ledger MCP"}, owner: user)
    done = List.last(board.columns)
    card = card_fixture(done, %{"title" => "Shipped today"})
    old = card_fixture(done, %{"title" => "Shipped last week"})
    now = DateTime.utc_now(:second)

    Repo.update_all(from(c in Card, where: c.id == ^card.id),
      set: [completed: true, completed_at: DateTime.add(now, -60, :second), evidence: "PR green"]
    )

    Repo.update_all(from(c in Card, where: c.id == ^old.id),
      set: [completed: true, completed_at: DateTime.add(now, -6 * 86_400, :second)]
    )

    theirs = board_fixture(%{"name" => "Theirs"}, owner: user_fixture("mcp-ledger-x@example.com"))
    %{board: board, card: card, old: old, theirs: theirs}
  end

  defp call(conn, args) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post(
      "/mcp",
      Jason.encode!(%{
        jsonrpc: "2.0",
        id: 1,
        method: "tools/call",
        params: %{name: "activity", arguments: args}
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

  defp lines(ledger), do: for(d <- ledger["days"], i <- d["items"], do: i["card"]["id"])

  test "view=ledger gives the ledger, since yesterday by default", ctx do
    ledger = ctx.conn |> call(%{board: ctx.board.code, view: "ledger"}) |> ok!()

    assert ledger["board"]["id"] == ctx.board.id
    assert ledger["count"] == 1
    assert lines(ledger) == [ctx.card.id]
    [%{"items" => [line]}] = ledger["days"]
    assert line["evidence"] == "PR green"
    assert line["events"] == ["completed"]
    assert line["card"]["url"] =~ "#card-ai-#{ctx.card.id}"
  end

  test "since widens it, as days or a date", ctx do
    assert ctx.conn
           |> call(%{board: ctx.board.code, view: "ledger", since: "7"})
           |> ok!()
           |> lines() ==
             [ctx.card.id, ctx.old.id]

    date = Date.utc_today() |> Date.add(-10) |> Date.to_iso8601()

    assert %{"count" => 2} =
             ctx.conn |> call(%{board: ctx.board.code, view: "ledger", since: date}) |> ok!()
  end

  test "a bad since and an unknown view are tool errors", ctx do
    assert ctx.conn |> call(%{board: ctx.board.code, view: "ledger", since: "soon"}) |> error!() =~
             "since is a date"

    assert ctx.conn |> call(%{board: ctx.board.code, view: "chart"}) |> error!() =~
             "view is log or ledger"

    assert ctx.conn |> call(%{view: "ledger"}) |> error!() =~ "board is required"

    assert ctx.conn |> call(%{board: ctx.board.code, view: "ledger", since: true}) |> error!() =~
             "since must be a string"
  end

  test "since may be a number of days", ctx do
    assert %{"count" => 2} =
             ctx.conn |> call(%{board: ctx.board.code, view: "ledger", since: 7}) |> ok!()
  end

  test "the log stays the default view", ctx do
    assert %{"activity" => [_ | _]} = ctx.conn |> call(%{board: ctx.board.code}) |> ok!()

    assert %{"activity" => [_ | _]} =
             ctx.conn |> call(%{board: ctx.board.code, view: "log"}) |> ok!()
  end

  test "a stranger's board reads as no board; a read-only token may read", ctx do
    assert ctx.conn |> call(%{board: ctx.theirs.code, view: "ledger"}) |> error!() =~ "no board"

    {token, _} = Accounts.create_api_token(ctx.user, "ro", scope: "read")
    conn = put_req_header(ctx.conn, "authorization", "Bearer " <> token)
    assert %{"count" => 1} = conn |> call(%{board: ctx.board.code, view: "ledger"}) |> ok!()
  end
end
