defmodule SlipdockWeb.KindFilterLiveTest do
  @moduledoc """
  The Filter bar's Kind section: cards, documents (a card whose whole content
  is the file on it) and wiki pages placed in a list. The board toggles them
  one click at a time; the other views carry them on the filter form, and so
  in the URL and in a saved view.
  """
  use SlipdockWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Boards, Wiki}

  setup %{conn: conn, user: user} do
    File.rm_rf!(Boards.uploads_dir())
    board = board_fixture(%{"name" => "Kinds", "code" => "kinds"}, owner: user)
    column = hd(board.columns)

    src = Path.join(System.tmp_dir!(), "kanban-kind-live-#{System.unique_integer([:positive])}")
    File.write!(src, "the spec they emailed")
    on_exit(fn -> File.rm(src) end)

    card = card_fixture(column, %{"title" => "Write the parser"})
    document = card_fixture(column, %{"title" => "spec.txt"})

    {:ok, _} =
      Boards.add_attachment(document, %{filename: "spec.txt", content_type: "text/plain"}, src)

    page = page_fixture(board, %{"title" => "Retro notes"}, user: user)
    {:ok, _} = Wiki.place(page, column)

    %{conn: conn, board: board, column: column, card: card, document: document, page: page}
  end

  test "the board narrows to one kind and back again", %{conn: conn, board: board} do
    {:ok, view, html} = live(conn, ~p"/boards/#{board}")

    assert html =~ "Write the parser"
    assert html =~ "spec.txt"
    assert html =~ "Retro notes"

    documents = view |> element(~s|button[phx-value-kind="document"]|) |> render_click()
    assert documents =~ "spec.txt"
    refute documents =~ "Write the parser"
    refute documents =~ "Retro notes"
    assert documents =~ "Documents only"

    # A second kind widens the filter rather than replacing it.
    both = view |> element(~s|button[phx-value-kind="page"]|) |> render_click()
    assert both =~ "spec.txt"
    assert both =~ "Retro notes"
    refute both =~ "Write the parser"

    cleared = view |> element("button", "Clear all filters") |> render_click()
    assert cleared =~ "Write the parser"
  end

  test "the wiki offers no Kind section, being pages throughout", %{conn: conn, board: board} do
    {:ok, view, _} = live(conn, ~p"/boards/#{board}/wiki")

    refute has_element?(view, ~s|button[phx-value-kind="page"]|)
  end

  test "the table view filters by kind, and says so in the URL", %{conn: conn, board: board} do
    {:ok, view, html} = live(conn, ~p"/boards/#{board}/table")

    assert html =~ "Retro notes"

    filtered = view |> form("#swim-config", %{"kinds" => ["card"]}) |> render_change()

    assert filtered =~ "Write the parser"
    refute filtered =~ "Retro notes"
    refute filtered =~ "spec.txt"
    assert_patch(view, ~p"/boards/#{board}/table?kinds=card")
  end
end
