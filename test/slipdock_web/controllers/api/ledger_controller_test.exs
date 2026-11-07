defmodule SlipdockWeb.API.LedgerControllerTest do
  @moduledoc """
  The ledger over HTTP (#1948): `GET /api/boards/:board/ledger` for a reader
  and a read-only token, the default window and `since`, a bad `since` (422),
  a stranger (404), and the line's fields and its "Look closer" link.
  """
  use SlipdockWeb.ConnCase, async: true

  import Ecto.Query
  import Slipdock.Fixtures

  alias Slipdock.{Access, Accounts, Repo}
  alias Slipdock.Boards.Card

  setup %{user: owner} do
    board = board_fixture(%{}, owner: owner)
    done = List.last(board.columns)
    card = card_fixture(done, %{"title" => "Shipped"})
    an_hour_ago = DateTime.add(DateTime.utc_now(:second), -3600, :second)

    Repo.update_all(from(c in Card, where: c.id == ^card.id),
      set: [
        completed: true,
        completed_at: an_hour_ago,
        verify_state: "accepted",
        verify_at: an_hour_ago,
        verify_by: %{"kind" => "agent", "agent" => "verifier", "via" => "cli"},
        evidence: "Built it; CI green",
        evidence_pr: "https://github.com/example/repo/pull/3"
      ]
    )

    old = card_fixture(done, %{"title" => "Old"})

    Repo.update_all(from(c in Card, where: c.id == ^old.id),
      set: [completed: true, completed_at: DateTime.add(an_hour_ago, -10 * 86_400, :second)]
    )

    reader = user_fixture("ledger-reader@example.com")
    {:ok, _} = Access.grant(board, reader, "read", owner)
    stranger = user_fixture("ledger-stranger@example.com")
    %{board: board, card: card, old: old, reader: reader, stranger: stranger}
  end

  defp as(user), do: user |> conn_as() |> put_req_header("accept", "application/json")

  defp ledger(conn, board, query \\ ""), do: get(conn, "/api/boards/#{board.code}/ledger#{query}")

  test "a reader gets what shipped since yesterday, with its evidence", ctx do
    body = ctx.reader |> as() |> ledger(ctx.board) |> json_response(200)

    assert body["board"]["id"] == ctx.board.id
    assert body["count"] == 1
    assert body["timezone"] == "Etc/UTC"
    assert {:ok, _, _} = DateTime.from_iso8601(body["since"])
    assert [%{"date" => date, "items" => [line]}] = body["days"]
    assert {:ok, _} = Date.from_iso8601(date)

    assert line["card"]["id"] == ctx.card.id
    assert line["card"]["title"] == "Shipped"

    assert line["card"]["url"] ==
             "/boards/#{ctx.board.id}/cards/#{ctx.card.id}#card-ai-#{ctx.card.id}"

    assert line["events"] == ["completed", "accepted"]
    assert line["accepted_by"] == %{"kind" => "agent", "name" => "agent “verifier”"}
    assert line["evidence"] == "Built it; CI green"
    assert line["pr"] == "https://github.com/example/repo/pull/3"
    assert line["should_broken"] == []
    assert line["on_board"] == true
    assert %{"seconds" => s, "ends" => "completed", "phases" => %{}} = line["lead_time"]
    assert is_integer(s)
  end

  test "since widens the window", ctx do
    body = ctx.reader |> as() |> ledger(ctx.board, "?since=30") |> json_response(200)
    assert body["count"] == 2

    ids = for d <- body["days"], i <- d["items"], do: i["card"]["id"]
    assert ids == [ctx.card.id, ctx.old.id]
  end

  test "a since it can't read is a 422", ctx do
    assert %{"error" => "since is a date" <> _} =
             ctx.reader |> as() |> ledger(ctx.board, "?since=soon") |> json_response(422)
  end

  test "a read-only token may read it", ctx do
    {token, _} = Accounts.create_api_token(ctx.reader, "ro", scope: "read")

    conn =
      build_conn()
      |> put_req_header("accept", "application/json")
      |> put_req_header("authorization", "Bearer " <> token)

    assert %{"count" => 1} = conn |> ledger(ctx.board) |> json_response(200)
  end

  test "a stranger can't see it", ctx do
    assert ctx.stranger |> as() |> ledger(ctx.board) |> json_response(404)
  end
end
