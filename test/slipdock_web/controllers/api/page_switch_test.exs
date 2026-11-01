defmodule SlipdockWeb.API.PageSwitchTest do
  @moduledoc "`GET /api/boards/:board/pages/switch`: the quick switcher over HTTP."
  use SlipdockWeb.ConnCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.Wiki

  setup %{conn: conn, user: user} do
    board = board_fixture(%{"name" => "Switch API", "code" => "switchapi"}, owner: user)
    {:ok, folder} = Wiki.create_folder(board, %{"name" => "Specs"})
    {:ok, page} = Wiki.create_page(board, %{"title" => "Retry policy"}, user: user)
    {:ok, _} = Wiki.file_page(page, folder)
    page_fixture(board, %{"title" => "Launch"})
    %{conn: put_req_header(conn, "accept", "application/json"), page: page}
  end

  test "fuzzy matches with their path, best first", %{conn: conn, page: page} do
    assert %{"matches" => [match]} =
             conn |> get("/api/boards/switchapi/pages/switch?q=rtpol") |> json_response(200)

    assert match["id"] == page.id
    assert match["path"] == "Switch API/Specs/Retry policy"
    assert match["matched"] == "title"
  end

  test "nothing typed lists the latest, and limit is kept in bounds", %{conn: conn} do
    assert %{"matches" => [_, _]} =
             conn |> get("/api/boards/switchapi/pages/switch") |> json_response(200)

    assert %{"matches" => [_]} =
             conn |> get("/api/boards/switchapi/pages/switch?limit=0") |> json_response(200)

    assert %{"matches" => [_, _]} =
             conn |> get("/api/boards/switchapi/pages/switch?limit=junk") |> json_response(200)
  end

  test "a board you cannot open is refused", %{conn: conn} do
    stranger = user_fixture("switch.stranger@example.com")
    board_fixture(%{"name" => "Private", "code" => "privswitch"}, owner: stranger)
    assert conn |> get("/api/boards/privswitch/pages/switch?q=x") |> json_response(404)
  end

  test "the caller's other boards are in the one vault, so ?vaults=all adds none (#1303)", %{
    conn: conn,
    user: user
  } do
    garden = board_fixture(%{"name" => "Garden", "code" => "swapi1303"}, owner: user)
    {:ok, rose} = Wiki.create_page(garden, %{"title" => "Retry roses"}, user: user)

    assert %{"matches" => plain} =
             conn |> get("/api/boards/switchapi/pages/switch?q=retry") |> json_response(200)

    assert %{"path" => "Garden/Retry roses", "vault" => nil} =
             Enum.find(plain, &(&1["id"] == rose.id))

    assert %{"matches" => wide} =
             conn
             |> get("/api/boards/switchapi/pages/switch?q=retry&vaults=all")
             |> json_response(200)

    assert wide == plain
  end
end
