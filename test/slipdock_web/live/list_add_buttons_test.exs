defmodule SlipdockWeb.ListAddButtonsTest do
  @moduledoc """
  The three things the foot of a list offers, and the board settings that say
  which of them to offer.

  All three add something to the list — a card, a wiki page placed in it, or
  a file on a card of its own. They are shortcuts, not new kinds of thing, so
  what they leave behind is what the board already knows how to draw.
  """
  use SlipdockWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Boards, Wiki}

  setup %{conn: conn, user: user} do
    board = board_fixture(%{"name" => "Adding", "code" => "adding"}, owner: user)
    %{conn: conn, board: board, column: hd(board.columns), user: user}
  end

  # One row of icons, so the hover text is what names them.
  defp offered(view, column) do
    for {what, selector} <- [
          card: ~s|button[aria-label="Add a card to #{column.name}"]|,
          page: ~s|a[aria-label="Add a page to #{column.name}"]|,
          document: ~s|button[aria-label="Add a document to #{column.name}"]|
        ],
        has_element?(view, selector),
        do: what
  end

  test "all three are offered by default", %{conn: conn, board: board, column: column} do
    {:ok, view, _html} = live(conn, ~p"/boards/#{board}")

    assert offered(view, column) == [:card, :page, :document]
  end

  test "add a page is a link straight into the wiki editor, carrying the list", %{
    conn: conn,
    board: board,
    column: column
  } do
    {:ok, view, _} = live(conn, ~p"/boards/#{board}")

    assert has_element?(
             view,
             ~s|a[aria-label="Add a page to #{column.name}"][href="/boards/#{board.id}/wiki/new?column=#{column.id}"]|
           )
  end

  test "a page written there is placed in the list when it is saved", %{
    conn: conn,
    board: board,
    column: column
  } do
    # The editor is the wiki's own — Markdown, not a card form — and it says
    # where the page will land.
    {:ok, view, html} = live(conn, ~p"/boards/#{board}/wiki/new?column=#{column.id}")
    assert html =~ "New page"
    assert html =~ "It will sit on the board in"
    assert html =~ column.name

    # The cursor is in the title: it is what you came here to type.
    assert has_element?(view, "#new-page-title[phx-hook='Focus']")

    view
    |> form("#page-form", page: %{title: "Retry policy", body: "## Approach"})
    |> render_submit()

    assert [%{title: "Retry policy"} = page] = Wiki.placed_in(column.id)
    assert page.column_id == column.id
    assert page.body =~ "## Approach"

    # A page in the wiki tree as well as a tile on the board.
    assert Enum.any?(Wiki.tree(board), &(&1.page.id == page.id))
  end

  test "without a list it is an ordinary new page", %{conn: conn, board: board, column: column} do
    {:ok, view, html} = live(conn, ~p"/boards/#{board}/wiki/new")
    refute html =~ "It will sit on the board in"

    view |> form("#page-form", page: %{title: "Just a doc"}) |> render_submit()

    assert Wiki.placed_in(column.id) == []
    assert [%{title: "Just a doc"}] = Wiki.list_pages(board)
  end

  test "a document lands as a card named after the file, with the file on it", %{
    conn: conn,
    board: board,
    column: column
  } do
    {:ok, view, _} = live(conn, ~p"/boards/#{board}")

    # The file input has to live in a form with a change binding, or
    # LiveView takes the file and does nothing with it.
    assert has_element?(view, "form#list-document-form[phx-change='validate_document']")

    # Which list the file belongs to is settled before the picker opens.
    render_click(view, "aim_document", %{"id" => column.id})

    upload =
      file_input(view, "#list-document-form", :list_document, [
        %{name: "Q3 plan.pdf", content: "%PDF-1.4 fake", type: "application/pdf"}
      ])

    render_upload(upload, "Q3 plan.pdf")

    assert [{:card, id}] = Boards.active_items(column.id)

    card = Boards.get_card!(id)
    assert card.title == "Q3 plan"
    assert [%{filename: "Q3 plan.pdf", content_type: "application/pdf"}] = card.attachments
  end

  test "a board can turn each of them off", %{conn: conn, board: board, column: column} do
    {:ok, _} = Boards.update_board(board, %{"add_page" => false, "add_document" => false})

    {:ok, view, _} = live(conn, ~p"/boards/#{board}")
    assert offered(view, column) == [:card]

    {:ok, _} =
      Boards.update_board(Boards.get_board!(board.id), %{
        "add_card" => false,
        "add_page" => true
      })

    {:ok, view, _} = live(conn, ~p"/boards/#{board}")
    assert offered(view, column) == [:page]
  end

  test "a reader is offered none of them", %{board: board, column: column, user: user} do
    reader = user_fixture("adding.reader@example.com")
    {:ok, _} = Slipdock.Access.grant(board, reader, "read", user)

    {:ok, view, _} = live(conn_as(reader), ~p"/boards/#{board}")
    assert offered(view, column) == []
  end

  test "editing a page leaves the cursor alone", %{conn: conn, board: board} do
    page = page_fixture(board, %{"title" => "Already written"})

    {:ok, view, _} = live(conn, ~p"/boards/#{board}/wiki/#{page.slug}/edit")
    refute has_element?(view, "[phx-hook='Focus']")
  end
end
