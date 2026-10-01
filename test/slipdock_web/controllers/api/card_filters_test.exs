defmodule SlipdockWeb.API.CardFiltersTest do
  @moduledoc """
  The date, dependency, assignee and kind filters on
  `GET /api/boards/:board/cards`.
  """
  use SlipdockWeb.ConnCase, async: false

  import Slipdock.Fixtures

  alias Slipdock.Boards

  setup %{conn: conn} do
    board = board_fixture(%{"name" => "API Filters", "code" => "apifilt"})
    [backlog | _] = board.columns
    today = Date.utc_today()

    late = card_fixture(backlog, %{"title" => "Late", "due_date" => Date.add(today, -2)})
    card_fixture(backlog, %{"title" => "Undated"})
    {:ok, _} = Boards.update_card(late, %{"assignee_id" => user_fixture().id})

    %{conn: put_req_header(conn, "accept", "application/json"), board: board}
  end

  defp titles(conn, query) do
    %{"cards" => cards} = conn |> get("/api/boards/apifilt/cards?" <> query) |> json_response(200)
    Enum.map(cards, & &1["title"])
  end

  test "due, deps and assignee filter, and “me” is the token's owner", %{conn: conn} do
    assert titles(conn, "due=overdue") == ["Late"]
    assert titles(conn, "due=none") == ["Undated"]
    assert titles(conn, "deps=free") |> Enum.sort() == ["Late", "Undated"]
    assert titles(conn, "assignee=none") == ["Undated"]
    assert titles(conn, "assignee=me") == ["Late"]
  end

  test "a value that is not a bucket is a 400, not a silent everything", %{conn: conn} do
    assert %{"error" => message} =
             conn |> get("/api/boards/apifilt/cards?due=yesterday") |> json_response(400)

    assert message =~ "due must be one of: overdue, today, week, month, has, none"

    assert %{"error" => message} =
             conn |> get("/api/boards/apifilt/cards?deps=tangled") |> json_response(400)

    assert message =~ "deps must be one of:"
  end

  test "kind tells a card from a document, and a page is not a card", %{
    conn: conn,
    board: board
  } do
    src = Path.join(System.tmp_dir!(), "kanban-api-kind-#{System.unique_integer([:positive])}")
    File.write!(src, "the spec they emailed")
    on_exit(fn -> File.rm(src) end)

    document = card_fixture(hd(board.columns), %{"title" => "spec.txt"})

    {:ok, _} =
      Boards.add_attachment(document, %{filename: "spec.txt", content_type: "text/plain"}, src)

    assert titles(conn, "kind=document") == ["spec.txt"]
    assert titles(conn, "kind=card") |> Enum.sort() == ["Late", "Undated"]

    %{"cards" => cards} = conn |> get("/api/boards/apifilt/cards") |> json_response(200)
    assert Enum.sort(Enum.map(cards, & &1["kind"])) == ["card", "card", "document"]

    # A wiki page is the third kind of thing in a list and is not a card, so
    # asking a card listing for one is a mistake worth saying out loud.
    assert %{"error" => message} =
             conn |> get("/api/boards/apifilt/cards?kind=page") |> json_response(400)

    assert message =~ "kind must be one of: card, document"
  end
end
