defmodule SlipdockWeb.PageCardFeaturesTest do
  @moduledoc """
  One switch for a whole wiki: whether its pages show the card contents under
  their prose (status, checklist, links, fields, votes, comments). Hidden,
  never deleted — turning it back on brings everything back.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures
  import Ecto.Query

  alias Slipdock.Boards
  alias Slipdock.Boards.Board

  setup %{conn: conn, user: user} do
    board = board_fixture(%{"name" => "Handbook", "code" => "handbook"}, owner: user)

    page =
      page_fixture(board, %{"title" => "Onboarding", "body" => "Read this first."}, user: user)

    %{conn: conn, board: board, page: page, user: user}
  end

  defp off!(board) do
    {:ok, board} = Boards.update_board(board, %{"page_card_features" => false})
    board
  end

  test "a wiki's pages show the card contents until it is turned off", %{
    conn: conn,
    board: board,
    page: page
  } do
    assert board.page_card_features

    {:ok, view, html} = live(conn, ~p"/boards/#{board}/wiki/#{page.slug}")
    assert has_element?(view, "#page-card-features")
    assert html =~ "Read this first."

    off!(board)

    {:ok, view, html} = live(conn, ~p"/boards/#{board}/wiki/#{page.slug}")
    refute has_element?(view, "#page-card-features")
    refute has_element?(view, "#page-card-features form")
    # The prose, the history link and the cards it is about stay.
    assert html =~ "Read this first."
    assert html =~ "see history"
    assert has_element?(view, "#page-cards")
  end

  test "it applies to every page in the wiki, and to no other board's", %{
    conn: conn,
    board: board,
    page: page,
    user: user
  } do
    other_page = page_fixture(board, %{"title" => "Leave"}, user: user)
    elsewhere = board_fixture(%{"name" => "Product", "code" => "product"}, owner: user)
    elsewhere_page = page_fixture(elsewhere, %{"title" => "Roadmap"}, user: user)

    off!(board)

    for p <- [page, other_page] do
      {:ok, view, _} = live(conn, ~p"/boards/#{board}/wiki/#{p.slug}")
      refute has_element?(view, "#page-card-features")
    end

    {:ok, view, _} = live(conn, ~p"/boards/#{elsewhere}/wiki/#{elsewhere_page.slug}")
    assert has_element?(view, "#page-card-features")
  end

  test "turning it off deletes nothing: a comment comes back with the switch", %{
    conn: conn,
    board: board,
    page: page
  } do
    {:ok, view, _} = live(conn, ~p"/boards/#{board}/wiki/#{page.slug}")
    view |> element("form[phx-submit='add_comment']") |> render_submit(%{body: "Still true?"})

    off!(board)
    {:ok, _view, html} = live(conn, ~p"/boards/#{board}/wiki/#{page.slug}")
    refute html =~ "Still true?"

    {:ok, _} = Boards.update_board(Boards.get_board!(board.id), %{"page_card_features" => true})
    {:ok, _view, html} = live(conn, ~p"/boards/#{board}/wiki/#{page.slug}")
    assert html =~ "Still true?"
  end

  test "a page opened from a list leaves them out of its panel too", %{
    conn: conn,
    board: board,
    page: page
  } do
    {:ok, _} = Slipdock.Wiki.place(page, hd(board.columns))

    {:ok, view, _} = live(conn, ~p"/boards/#{board}")
    render_click(view, "open_page", %{"id" => page.id})
    assert has_element?(view, "#page-panel-card-features")

    off!(board)

    {:ok, view, _} = live(conn, ~p"/boards/#{board}")
    render_click(view, "open_page", %{"id" => page.id})
    assert has_element?(view, "#page-panel")
    refute has_element?(view, "#page-panel-card-features")
  end

  test "it is set in the board's settings", %{conn: conn, board: board} do
    {:ok, view, _} = live(conn, ~p"/boards/#{board}/settings")
    assert has_element?(view, "#board-page-card-features[checked]")

    view |> form("#board-form", board: %{"page_card_features" => "false"}) |> render_submit()
    refute Boards.get_board!(board.id).page_card_features

    {:ok, view, _} = live(conn, ~p"/boards/#{board}/settings")
    refute has_element?(view, "#board-page-card-features[checked]")
    view |> form("#board-form", board: %{"page_card_features" => "true"}) |> render_submit()
    assert Boards.get_board!(board.id).page_card_features
  end

  test "the API reads and sets it, and refuses a value that is not a boolean", %{
    conn: conn,
    board: board
  } do
    conn = put_req_header(conn, "accept", "application/json")

    body =
      conn
      |> patch(~p"/api/boards/#{board.code}", %{"page_card_features" => false})
      |> json_response(200)

    assert body["board"]["page_card_features"] == false

    body = conn |> get(~p"/api/boards/#{board.code}") |> json_response(200)
    assert body["board"]["page_card_features"] == false

    assert conn
           |> patch(~p"/api/boards/#{board.code}", %{"page_card_features" => "sometimes"})
           |> json_response(422)

    refute Boards.get_board!(board.id).page_card_features
  end

  test "export and import carry it, and an older export means on", %{board: board, user: user} do
    off!(board)
    doc = user |> Slipdock.Portable.export() |> Jason.encode!()
    {:ok, _} = Slipdock.Portable.import(user, doc)

    copies =
      Slipdock.Repo.all(from b in Board, where: b.name == "Handbook" and b.id != ^board.id)

    assert [%{page_card_features: false}] = copies

    older =
      doc
      |> Jason.decode!()
      |> update_in(["boards"], fn trees ->
        Enum.map(
          trees,
          &update_in(&1, ["root"], fn root -> Map.delete(root, "page_card_features") end)
        )
      end)
      |> Jason.encode!()

    {:ok, _} = Slipdock.Portable.import(user, older)

    copies =
      Slipdock.Repo.all(from b in Board, where: b.name == "Handbook" and b.id != ^board.id)

    assert Enum.count(copies, & &1.page_card_features) == 1
  end
end
