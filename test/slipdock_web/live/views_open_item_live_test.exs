defmodule SlipdockWeb.ViewsOpenItemLiveTest do
  # The table, the calendar and the timeline open a card, a placed wiki page
  # and (on the timeline) a card from another board the one way, through
  # `open_item/1`, and link a page's document icon with `page_path/1` (#2890).
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.Wiki

  setup %{user: user} do
    board = board_fixture(%{"name" => "Opened"}, owner: user)
    [todo | _] = board.columns

    card =
      card_fixture(todo, %{
        "title" => "The work",
        "start_date" => "2030-01-14",
        "due_date" => "2030-01-15"
      })

    page = page_fixture(board, %{"title" => "The spec"}, user: user)
    {:ok, _} = Wiki.place(page, todo)

    {:ok, page} =
      Wiki.update_page(Wiki.get_page!(page.id), %{
        "start_date" => "2030-01-14",
        "due_date" => "2030-01-15"
      })

    %{board: reload(board), card: card, page: page}
  end

  test "the table's title opens a card and a page, and the icon links the document", ctx do
    {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/table")
    assert_doc_link(view, "#row-all-page-#{ctx.page.id}", ctx.page)
    refute has_element?(view, "#row-all-#{ctx.card.id} a[title='Open the document']")

    view |> element("#row-all-#{ctx.card.id} [role=link][title='The work']") |> render_click()
    assert assert_patch(view) =~ "/boards/#{ctx.board.id}/table/cards/#{ctx.card.id}"

    {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/table")

    view
    |> element("#row-all-page-#{ctx.page.id} [role=link][title='The spec']")
    |> render_click()

    assert assert_patch(view) =~ "page=#{ctx.page.id}"
  end

  test "a calendar chip opens a card and a page, and carries each one's item id", ctx do
    path = ~p"/boards/#{ctx.board}/calendar?date=2030-01-15"
    {:ok, view, _} = live(ctx.conn, path)

    card_chip = "#cal-2030-01-15-#{ctx.card.id}[data-id='#{ctx.card.id}']"
    page_chip = "#cal-2030-01-15-page-#{ctx.page.id}[data-id='page-#{ctx.page.id}']"
    assert has_element?(view, card_chip)
    assert has_element?(view, page_chip)
    assert_doc_link(view, page_chip, ctx.page)

    view |> element(card_chip) |> render_click()
    assert assert_patch(view) =~ "/boards/#{ctx.board.id}/calendar/cards/#{ctx.card.id}"

    {:ok, view, _} = live(ctx.conn, path)
    view |> element(page_chip) |> render_click()
    assert assert_patch(view) =~ "page=#{ctx.page.id}"
  end

  test "a timeline row opens a card and a page, and links the document", ctx do
    path = ~p"/boards/#{ctx.board}/timeline?date=2030-01-15"
    {:ok, view, _} = live(ctx.conn, path)
    page_row = "#tl-all-page-#{ctx.page.id}"
    assert_doc_link(view, page_row, ctx.page)

    view |> element("#tl-all-#{ctx.card.id} [role=link]", "The work") |> render_click()
    assert assert_patch(view) =~ "/boards/#{ctx.board.id}/timeline/cards/#{ctx.card.id}"

    {:ok, view, _} = live(ctx.conn, path)
    view |> element("#{page_row} [role=link]", "The spec") |> render_click()
    assert assert_patch(view) =~ "page=#{ctx.page.id}"
  end

  test "the timeline's Unscheduled tray opens an undated card and an undated page", ctx do
    [todo | _] = ctx.board.columns
    loose = card_fixture(todo, %{"title" => "Loose card"})
    undated = page_fixture(ctx.board, %{"title" => "Loose page"})
    {:ok, _} = Wiki.place(undated, todo)

    path = ~p"/boards/#{ctx.board}/timeline?date=2030-01-15"
    {:ok, view, _} = live(ctx.conn, path)

    view |> element("#dateless-#{loose.id} [role=link]", "Loose card") |> render_click()
    assert assert_patch(view) =~ "/boards/#{ctx.board.id}/timeline/cards/#{loose.id}"

    {:ok, view, _} = live(ctx.conn, path)
    view |> element("#dateless-page-#{undated.id} [role=link]", "Loose page") |> render_click()
    assert assert_patch(view) =~ "page=#{undated.id}"
  end

  test "a subcard on the timeline opens on its own board's timeline", ctx do
    {:ok, t} = Slipdock.Boards.Templates.find_template(nil, "Simple")
    {:ok, _} = sub_board(ctx.card, t)
    sub = Slipdock.Boards.Cards.get_card!(ctx.card.id).sub_board
    sub = reload(sub)

    kid =
      card_fixture(hd(sub.columns), %{
        "title" => "The subtask",
        "start_date" => "2030-01-14",
        "due_date" => "2030-01-15"
      })

    {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/timeline?date=2030-01-15&depth=all")

    assert {:error, {:live_redirect, %{to: to}}} =
             view |> element("#tl-all-#{kid.id} [role=link]", "The subtask") |> render_click()

    assert to == ~p"/boards/#{sub.id}/timeline/cards/#{kid.id}"
  end

  test "the phone's schedule rows open a card and a page, and link the document", ctx do
    path = ~p"/boards/#{ctx.board}/timeline?date=2030-01-15"
    {:ok, view, _} = live(phone(ctx.conn), path)
    page_row = "#tl-row-page-#{ctx.page.id}"
    assert_doc_link(view, page_row, ctx.page)
    refute has_element?(view, "#tl-row-#{ctx.card.id} a[title='Open the document']")

    view |> element("#tl-row-#{ctx.card.id} [role=link]", "The work") |> render_click()
    assert assert_patch(view) =~ "/boards/#{ctx.board.id}/timeline/cards/#{ctx.card.id}"

    {:ok, view, _} = live(phone(ctx.conn), path)
    view |> element("#{page_row} [role=link]", "The spec") |> render_click()
    assert assert_patch(view) =~ "page=#{ctx.page.id}"
  end

  test "a subcard in the phone's schedule rows opens on its own board's timeline", ctx do
    {:ok, t} = Slipdock.Boards.Templates.find_template(nil, "Simple")
    {:ok, _} = sub_board(ctx.card, t)
    sub = reload(Slipdock.Boards.Cards.get_card!(ctx.card.id).sub_board)

    kid =
      card_fixture(hd(sub.columns), %{
        "title" => "The subtask",
        "start_date" => "2030-01-14",
        "due_date" => "2030-01-15"
      })

    {:ok, view, _} =
      live(phone(ctx.conn), ~p"/boards/#{ctx.board}/timeline?date=2030-01-15&depth=all")

    assert {:error, {:live_redirect, %{to: to}}} =
             view |> element("#tl-row-#{kid.id} [role=link]", "The subtask") |> render_click()

    assert to == ~p"/boards/#{sub.id}/timeline/cards/#{kid.id}"
  end

  defp assert_doc_link(view, scope, page) do
    assert has_element?(
             view,
             "#{scope} a[title='Open the document'][href='/boards/#{page.board_id}/wiki/#{page.slug}']"
           )
  end
end
