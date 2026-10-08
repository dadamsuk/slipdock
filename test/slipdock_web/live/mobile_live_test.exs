defmodule SlipdockWeb.MobileLiveTest do
  @moduledoc """
  The phone's renderings.

  A board's views do not simply shrink below `sm`: the calendar becomes an
  agenda, the swimlane grid stacks, the timeline becomes a schedule, and the
  two tables turn each row on its side. Which one you get is decided on the
  server from the window width, so these tests mount with a phone's width in
  the connect params and check that the right thing came back.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  setup do
    board = board_fixture(%{"name" => "Phone"})
    [backlog, todo | _] = board.columns

    span =
      card_fixture(backlog, %{
        "title" => "Spanning card",
        "start_date" => Date.to_iso8601(Date.utc_today()),
        "due_date" => Date.to_iso8601(Date.add(Date.utc_today(), 5))
      })

    today =
      card_fixture(todo, %{
        "title" => "Due today",
        "due_date" => Date.to_iso8601(Date.utc_today())
      })

    loose = card_fixture(todo, %{"title" => "Undated card"})
    %{board: reload(board), span: span, today: today, loose: loose}
  end

  describe "the width the server renders for" do
    test "comes from the connect params", %{conn: conn, board: board} do
      {:ok, view, _} = live(phone(conn), ~p"/boards/#{board}")
      assert render(view) =~ ~s(id="list-pager")

      {:ok, wide, _} = live(conn, ~p"/boards/#{board}")
      refute render(wide) =~ ~s(id="list-pager")
    end

    test "follows the window when it is resized", %{conn: conn, board: board} do
      {:ok, view, _} = live(phone(conn), ~p"/boards/#{board}")
      assert render(view) =~ ~s(id="list-pager")

      html = view |> element("#viewport") |> render_hook("viewport", %{"width" => 1280})
      refute html =~ ~s(id="list-pager")

      html = view |> element("#viewport") |> render_hook("viewport", %{"width" => 375})
      assert html =~ ~s(id="list-pager")
    end
  end

  describe "the board" do
    test "pages one list at a time, with a strip naming them all", %{conn: conn, board: board} do
      {:ok, view, html} = live(phone(conn), ~p"/boards/#{board}")

      assert html =~ ~s(id="list-pager")
      # A tab per list, each naming its list and counting its cards.
      for column <- board.columns do
        assert has_element?(view, ~s(#list-pager [data-column="#{column.id}"]), column.name)
      end

      # And the columns themselves are a viewport wide, not the desktop's 18rem.
      column = hd(board.columns)
      assert has_element?(view, "#column-#{column.id}.kanban-column.w-screen.snap-start")
      refute has_element?(view, "#column-#{column.id}.w-72")
    end

    test "a list is the page: no margin round it, no well behind it (#419)", %{
      conn: conn,
      board: board
    } do
      {:ok, view, _} = live(phone(conn), ~p"/boards/#{board}")
      column = hd(board.columns)

      # Nothing between the edge of the screen and the list...
      assert has_element?(view, "#columns.gap-0")
      refute has_element?(view, "#columns.p-4")
      refute has_element?(view, "#board-scroll.scroll-pl-4")
      # ...and the list draws no box of its own: the cards sit on the page.
      refute has_element?(view, "#column-#{column.id}.rounded-2xl")
      refute has_element?(view, "#column-#{column.id}.bg-base-300\\/60")
      assert has_element?(view, "#cards-#{column.id}.px-3")
      # The add-a-list slot pages like a list rather than leaving 18rem.
      assert has_element?(view, "#columns > div.w-screen.snap-start.p-3")
    end

    test "the desktop keeps its boxed lists", %{conn: conn, board: board} do
      {:ok, view, _} = live(conn, ~p"/boards/#{board}")
      column = hd(board.columns)

      assert has_element?(view, "#columns.gap-4.p-4")
      assert has_element?(view, "#column-#{column.id}.w-72.rounded-2xl.bg-base-300\\/60")
      assert has_element?(view, "#cards-#{column.id}.px-2")
      refute has_element?(view, "#column-#{column.id}.w-screen")
    end
  end

  describe "the calendar" do
    test "is an agenda, not a seven-column grid", %{conn: conn, board: board, today: today} do
      {:ok, _view, html} = live(phone(conn), ~p"/boards/#{board}/calendar")

      refute html =~ "grid-template-columns: repeat(7"
      assert html =~ "Today"
      assert html =~ today.title

      {:ok, _wide, wide} = live(conn, ~p"/boards/#{board}/calendar")
      assert wide =~ "grid-template-columns: repeat(7"
    end

    test "still adds a card to a day", %{conn: conn, board: board} do
      {:ok, view, _} = live(phone(conn), ~p"/boards/#{board}/calendar")
      today = Date.to_iso8601(Date.utc_today())

      view |> element(~s(button[phx-value-cell="#{today}"])) |> render_click()

      view
      |> form(~s(form[phx-submit="cal_quick_add"]), %{"title" => "Added from a phone"})
      |> render_submit()

      assert render(view) =~ "Added from a phone"
    end
  end

  describe "the swimlane grid" do
    test "stacks its axes instead of crossing them", %{conn: conn, board: board} do
      {:ok, _view, html} = live(phone(conn), ~p"/boards/#{board}/swimlanes")

      assert html =~ "swim-cell-stacked"
      refute html =~ "grid-template-columns: 13rem"

      {:ok, _wide, wide} = live(conn, ~p"/boards/#{board}/swimlanes")
      refute wide =~ "swim-cell-stacked"
      assert wide =~ "grid-template-columns:"
    end
  end

  describe "the timeline" do
    test "is a schedule with dates in words", %{conn: conn, board: board, span: span} do
      {:ok, _view, html} = live(phone(conn), ~p"/boards/#{board}/timeline")

      assert html =~ ~s(id="tl-row-#{span.id}")
      refute html =~ "tl-bar-span"
      assert html =~ Calendar.strftime(span.due_date, "%-d %b")

      {:ok, _wide, wide} = live(conn, ~p"/boards/#{board}/timeline")
      assert wide =~ "tl-bar"
      refute wide =~ ~s(id="tl-row-#{span.id}")
    end
  end

  describe "the table" do
    test "gives each card its own block of labelled fields", %{conn: conn, board: board} do
      {:ok, view, _html} = live(phone(conn), ~p"/boards/#{board}/table")

      refute has_element?(view, "table#card-table")
      assert has_element?(view, "div#card-table")

      # The fields are the table's own cells, so they still edit in place.
      [_backlog, todo | _] = board.columns
      card = hd(Slipdock.Boards.get_board!(board.id).columns |> hd() |> Map.fetch!(:cards))

      view
      |> element(~s(form#col-#{card.id}))
      |> render_change(%{"card_id" => card.id, "field" => "column_id", "value" => todo.id})

      assert Slipdock.Boards.get_card!(card.id).column_id == todo.id
    end
  end

  describe "the prioritise view" do
    test "keeps the vote buttons on the screen", %{conn: conn, board: board, span: span} do
      {:ok, view, _html} = live(phone(conn), ~p"/boards/#{board}/prioritise")

      assert has_element?(view, "ul#prioritise-table")
      refute has_element?(view, "table#prioritise-table")

      view
      |> element(~s([phx-click="prio_vote"][phx-value-card_id="#{span.id}"][phx-value-count="1"]))
      |> render_click()

      assert Slipdock.Boards.get_card!(span.id) |> Slipdock.Boards.Card.vote_total() == 1
    end
  end

  describe "moving a card between lists" do
    test "the card's list is a picker at the top of the modal", %{conn: conn, board: board} do
      [backlog, todo | _] = board.columns
      card = card_fixture(backlog, %{"title" => "Needs moving"})

      {:ok, view, _} = live(phone(conn), ~p"/boards/#{board}/cards/#{card.id}")

      # Not buried in the sidebar under everything else: in the line that
      # says where the card is, right beneath its title.
      assert has_element?(view, ~s(#card-form select[name="card[column_id]"]))

      view
      |> form("#card-form", %{"card" => %{"column_id" => todo.id}})
      |> render_change()

      assert Slipdock.Boards.get_card!(card.id).column_id == todo.id
    end

    test "every card on the board carries a move menu", %{conn: conn, board: board} do
      [backlog, todo | _] = board.columns
      card = card_fixture(backlog, %{"title" => "Drag-free"})

      {:ok, view, _} = live(phone(conn), ~p"/boards/#{board}")

      assert has_element?(view, ~s(#move-#{card.id}[popovertarget="move-menu-#{card.id}"]))

      view
      |> element(~s(#move-menu-#{card.id} button[phx-value-to="#{todo.id}"]))
      |> render_click()

      assert Slipdock.Boards.get_card!(card.id).column_id == todo.id
    end

    test "a read-only board offers neither", %{conn: conn, user: user} do
      owner = user_fixture("someone@example.com")
      board = board_fixture(%{"name" => "Theirs"}, owner: owner)
      card = card_fixture(hd(board.columns), %{"title" => "Not yours"})
      {:ok, _} = Slipdock.Access.grant(board, user, "read", owner)

      {:ok, view, _} = live(phone(conn), ~p"/boards/#{board}")
      refute has_element?(view, "#move-#{card.id}")

      {:ok, view, _} = live(phone(conn), ~p"/boards/#{board}/cards/#{card.id}")
      refute has_element?(view, ~s(#card-form select[name="card[column_id]"]))
    end
  end

  describe "the card modal" do
    test "wraps: nothing in it is wider than the phone", %{conn: conn, board: board} do
      [backlog | _] = board.columns

      card =
        card_fixture(backlog, %{
          "title" => "A card with a long dependency",
          "description" => String.duplicate("supercalifragilistic ", 20)
        })

      other =
        card_fixture(backlog, %{
          "title" =>
            "No shared broker interface — order, guardrail and reconcile logic copy-pasted"
        })

      {:ok, _} = Slipdock.Boards.add_dependency(card, other)

      {:ok, _view, html} = live(phone(conn), ~p"/boards/#{board}/cards/#{card.id}")

      # The grid the modal lays out in has to cap its own track, or the
      # `truncate`d dependency title — whose min-content is the whole line —
      # makes the card wider than the screen and scrolls it sideways.
      assert html =~ "grid grid-cols-1 md:grid-cols-[minmax(0,1fr)_260px]"
      assert html =~ ~s(class="min-w-0 space-y-7 p-6")
    end
  end

  describe "the floating navigation (#354)" do
    test "carries the navigation and quick add", %{conn: conn, board: board} do
      {:ok, view, _} = live(phone(conn), ~p"/boards/#{board}")

      assert has_element?(view, "#mobile-bar")
      assert has_element?(view, "#mobile-dock a[href='/work']", "My work")
      assert has_element?(view, "#mobile-dock a[href='/favourites']", "Favourites")
      assert has_element?(view, "#mobile-dock #mobile-menu")
      assert has_element?(view, "#mobile-dock #quick-add-fab")
      assert has_element?(view, "#mobile-dock button[phx-click=toggle_alerts]", "Alerts")
    end

    test "floats over the bottom-left corner instead of taking a strip of the page", %{
      conn: conn,
      board: board
    } do
      {:ok, view, html} = live(phone(conn), ~p"/boards/#{board}")

      assert has_element?(view, "nav#mobile-bar.fixed.left-3.sm\\:hidden")
      refute has_element?(view, "nav#mobile-bar.shrink-0")
      refute has_element?(view, "nav#mobile-bar.border-t")
      assert html =~ "bottom-[calc(1rem+env(safe-area-inset-bottom))]"
    end

    test "starts folded: one button, the row hidden until it is tapped", %{
      conn: conn,
      board: board
    } do
      {:ok, view, _} = live(phone(conn), ~p"/boards/#{board}")

      # The button is the first thing in the corner, ahead of the row.
      assert has_element?(view, "#mobile-bar > button#mobile-fab:first-child")
      assert has_element?(view, "#mobile-fab[aria-expanded=false][aria-controls=mobile-dock]")
      assert has_element?(view, "#mobile-dock.hidden")
      # Bars when folded, a cross when open — chosen by aria-expanded in CSS.
      assert has_element?(view, "#mobile-fab .hero-squares-2x2.group-aria-expanded\\:hidden")
      assert has_element?(view, "#mobile-fab .hero-x-mark.hidden.group-aria-expanded\\:block")
    end

    test "the button flies the row out and back, and a tap elsewhere folds it", %{
      conn: conn,
      board: board
    } do
      {:ok, view, _} = live(phone(conn), ~p"/boards/#{board}")

      [toggle] = view |> element("#mobile-fab") |> render() |> js_ops("phx-click")
      assert [["toggle", toggle_args], ["toggle_attr", attr_args]] = toggle
      assert toggle_args["to"] == "#mobile-dock"
      assert toggle_args["display"] == "flex"
      assert attr_args["to"] == "#mobile-fab"
      assert attr_args["attr"] == ["aria-expanded", "true", "false"]

      [away] = view |> element("#mobile-bar") |> render() |> js_ops("phx-click-away")
      assert [["hide", hide_args], ["set_attr", set_args]] = away
      assert hide_args["to"] == "#mobile-dock"
      assert set_args["to"] == "#mobile-fab"
      assert set_args["attr"] == ["aria-expanded", "false"]
    end

    test "marks the folded button when alerts are waiting", %{conn: conn, board: board} do
      {:ok, view, _} = live(phone(conn), ~p"/boards/#{board}")
      refute has_element?(view, "#mobile-fab-alert")

      rule_fixture(board, %{
        "trigger" => %{"type" => "card_created"},
        "actions" => [%{"type" => "alert", "title" => "Look", "severity" => "urgent"}]
      })

      card_fixture(hd(board.columns), %{"title" => "Raises one"})

      {:ok, view, _} = live(phone(conn), ~p"/boards/#{board}")
      assert has_element?(view, "#mobile-fab #mobile-fab-alert.bg-error")
      # Open, the bell carries the count, so the dot steps aside.
      assert has_element?(view, "#mobile-fab-alert.group-aria-expanded\\:hidden")
    end

    test "the alerts panel opens above the button, not behind it", %{conn: conn, board: board} do
      {:ok, view, _} = live(phone(conn), ~p"/boards/#{board}")

      html = view |> element("#mobile-dock button[phx-click=toggle_alerts]") |> render_click()
      assert has_element?(view, "#alerts-panel")
      assert html =~ "bottom-[calc(4.5rem+env(safe-area-inset-bottom)+0.5rem)]"
    end

    test "is not there for someone signed out" do
      {:ok, view, _} = live(phone(Phoenix.ConnTest.build_conn()), ~p"/login")
      refute has_element?(view, "#mobile-bar")
      refute has_element?(view, "#mobile-fab")
    end

    test "quick add opens from it and puts a card on the default board", %{conn: conn} do
      Slipdock.AIStub.reply_with(%{
        "title" => "Caught on the train",
        "column" => "To Do",
        "priority" => "high"
      })

      inbox = board_fixture(%{"name" => "Inbox"})
      user = user_fixture()
      todo = Enum.find(inbox.columns, &(&1.name == "To Do")) || hd(inbox.columns)

      {:ok, _} =
        Slipdock.Accounts.update_quick_add(user, %{
          "quick_add_board_id" => inbox.id,
          "quick_add_column_id" => todo.id
        })

      {:ok, view, _} = live(phone(conn), ~p"/boards/#{inbox}")

      refute has_element?(view, "#quick-add-panel")
      view |> element("#quick-add-fab") |> render_click()
      assert has_element?(view, "#quick-add-panel")
      assert render(view) =~ "Goes to"

      view
      |> form("#quick-add-form-0", %{"text" => "caught on the train, urgent"})
      |> render_submit()

      assert render_async(view) =~ "added to Inbox › To Do"

      titles =
        inbox.id
        |> Slipdock.Boards.get_board!()
        |> Map.fetch!(:columns)
        |> Enum.flat_map(& &1.cards)

      assert Enum.map(titles, & &1.title) == ["Caught on the train"]
    end

    test "is not there on a desktop", %{conn: conn, board: board} do
      {:ok, view, _} = live(conn, ~p"/boards/#{board}")
      # The bar renders at every width but hides itself above `sm`; what
      # matters is that the desktop header still owns quick add and alerts.
      assert has_element?(view, "#quick-add-open")
      assert has_element?(view, "#alerts-bar")
    end
  end

  describe "the palettes a phone has no Ctrl for" do
    test "the header opens the card finder", %{conn: conn, board: board, today: today} do
      {:ok, view, _} = live(phone(conn), ~p"/boards/#{board}")

      view
      |> element("button[phx-click=shortcut_panel][phx-value-panel=find]")
      |> render_click()

      assert has_element?(view, "#key-palette")
      assert has_element?(view, "#palette-q-find")

      html =
        view |> form("#key-palette form", %{"q" => "due"}) |> render_change()

      assert html =~ today.title
      assert html =~ ~s(href="/boards/#{board.id}/cards/#{today.id}")
    end

    test "the header opens the command palette", %{conn: conn, board: board} do
      {:ok, view, _} = live(phone(conn), ~p"/boards/#{board}")

      view
      |> element("button[phx-click=shortcut_panel][phx-value-panel=command]")
      |> render_click()

      assert has_element?(view, "#key-palette")
      assert has_element?(view, "#palette-q-command")
      assert render(view) =~ "My work"
    end

    test "the same button closes what it opened", %{conn: conn, board: board} do
      {:ok, view, _} = live(phone(conn), ~p"/boards/#{board}")
      button = "button[phx-click=shortcut_panel][phx-value-panel=command]"

      view |> element(button) |> render_click()
      assert has_element?(view, "#key-palette")

      view |> element(button) |> render_click()
      refute has_element?(view, "#key-palette")
    end
  end

  # The JS commands an attribute carries, decoded from the rendered element.
  defp js_ops(html, attr) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.attribute(attr)
    |> Enum.take(1)
    |> Enum.map(&Jason.decode!/1)
  end
end
