defmodule SlipdockWeb.CopyCardAPITest do
  @moduledoc "`POST /api/cards/:id/copy`: where the copy goes, and who may make one."
  use SlipdockWeb.ConnCase, async: true

  import Slipdock.Fixtures
  alias Slipdock.{Access, Accounts, Boards}

  setup %{user: owner} do
    board = board_fixture(%{}, owner: owner)
    [backlog, todo | _] = board.columns
    card = card_fixture(backlog, %{"title" => "Weekly review", "flags" => ["blocked"]})
    {:ok, _} = Boards.add_checklist_item(card, "Look back")
    after_it = card_fixture(backlog, %{"title" => "Next one"})

    reader = user_fixture("reader@example.com")
    {:ok, _} = Access.grant(board, reader, "read", owner)

    %{board: board, backlog: backlog, todo: todo, card: card, after_it: after_it, reader: reader}
  end

  defp as(user), do: user |> conn_as() |> put_req_header("accept", "application/json")

  test "by default lands straight after the original, in its list", ctx do
    assert %{"card" => copy, "copied_from" => from} =
             as(ctx.user) |> post("/api/cards/#{ctx.card.id}/copy") |> json_response(201)

    assert from == ctx.card.id
    assert copy["title"] == "Weekly review"
    assert copy["flags"] == []

    assert %{"done" => 0, "items" => [%{"text" => "Look back", "done" => false}]} =
             copy["checklist"]

    ids = ctx.backlog.id |> Boards.active_items() |> Enum.map(fn {:card, id} -> id end)
    assert ids == [ctx.card.id, copy["id"], ctx.after_it.id]
  end

  test "into another list, at the top, renamed", ctx do
    card_fixture(ctx.todo, %{"title" => "Already there"})

    assert %{"card" => copy} =
             as(ctx.user)
             |> post("/api/cards/#{ctx.card.id}/copy", %{
               column: ctx.todo.name,
               at: "top",
               title: "Weekly review (copy)"
             })
             |> json_response(201)

    assert copy["title"] == "Weekly review (copy)"
    assert copy["column_id"] == ctx.todo.id
    assert [{:card, top} | _] = Boards.active_items(ctx.todo.id)
    assert top == copy["id"]
  end

  test "onto another board", ctx do
    other = board_fixture(%{}, owner: ctx.user)

    assert %{"card" => copy} =
             as(ctx.user)
             |> post("/api/cards/#{ctx.card.id}/copy", %{board: other.id})
             |> json_response(201)

    assert copy["board_id"] == other.id
    assert copy["column_id"] == hd(other.columns).id
  end

  test "refuses a bad `at`, an unknown list and a missing card", ctx do
    assert %{"error" => error} =
             as(ctx.user)
             |> post("/api/cards/#{ctx.card.id}/copy", %{at: "sideways"})
             |> json_response(400)

    assert error =~ "top, bottom, after"

    as(ctx.user)
    |> post("/api/cards/#{ctx.card.id}/copy", %{column: "Nowhere"})
    |> json_response(404)

    as(ctx.user) |> post("/api/cards/999999999/copy") |> json_response(404)
  end

  test "a reader can't copy onto the board they only read, nor can a read-only token", ctx do
    as(ctx.reader) |> post("/api/cards/#{ctx.card.id}/copy") |> json_response(403)

    {token, _} = Accounts.create_api_token(ctx.user, "ro", scope: "read")

    build_conn()
    |> put_req_header("accept", "application/json")
    |> put_req_header("authorization", "Bearer " <> token)
    |> post("/api/cards/#{ctx.card.id}/copy")
    |> json_response(403)

    # Nothing was made either way.
    assert length(Boards.active_items(ctx.backlog.id)) == 2
  end

  test "a reader may copy onto a board of their own", ctx do
    mine = board_fixture(%{}, owner: ctx.reader)

    assert %{"card" => copy} =
             as(ctx.reader)
             |> post("/api/cards/#{ctx.card.id}/copy", %{board: mine.id})
             |> json_response(201)

    assert copy["board_id"] == mine.id
  end
end
