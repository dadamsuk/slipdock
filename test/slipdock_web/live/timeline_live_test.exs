defmodule SlipdockWeb.TimelineLiveTest do
  use SlipdockWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures
  alias Slipdock.Boards
  alias Slipdock.Swimlanes.Config
  alias Slipdock.Timeline

  @today ~D[2030-01-15]

  setup do
    board = board_fixture(%{"name" => "Scheduled"})
    [backlog, todo | _] = board.columns

    span =
      card_fixture(backlog, %{
        "title" => "Span",
        "priority" => "high",
        "start_date" => "2030-01-10",
        "due_date" => "2030-01-20"
      })

    due = card_fixture(todo, %{"title" => "Due only", "due_date" => "2030-01-15"})
    loose = card_fixture(todo, %{"title" => "Loose"})
    far = card_fixture(todo, %{"title" => "Far", "due_date" => "2031-06-01"})
    %{board: reload(board), span: span, due: due, loose: loose, far: far}
  end

  test "start dates are validated and logged" do
    board = board_fixture()
    [col | _] = board.columns
    card = card_fixture(col, %{"title" => "Dated", "start_date" => "2030-02-01"})

    assert {:error, cs} = Boards.update_card(card, %{"due_date" => "2030-01-01"})
    assert {"must be on or before the due date", _} = cs.errors[:start_date]
    assert {:ok, _} = Boards.update_card(card, %{"due_date" => "2030-02-05"})
    assert Enum.any?(Boards.list_activities(board.id), &(&1.message =~ "set due date"))
  end

  test "Timeline.build places bars in a window around the anchor", %{board: board} do
    config = %{Config.defaults("timeline") | date: "2030-01-15", unit: "week"}
    tl = Timeline.build(board, config, @today)

    # 3 weeks before the anchor's week, 16 weeks in all.
    assert tl.window.from == ~D[2029-12-24]
    assert tl.window.days == 112
    assert tl.window.today == 22
    assert tl.title == "Dec 2029 – Apr 2030"
    assert tl.prev == "2029-09-24" and tl.next == "2030-05-06"
    assert Enum.map(tl.window.header, & &1.label) == ["Dec 2029", "Jan", "Feb", "Mar", "Apr"]
    assert hd(tl.window.units) == %{label: "24 Dec", from: 0, span: 7, tone: :past}

    [%{label: "All cards", bars: bars}] = tl.groups

    assert [
             %{card: %{title: "Span"}, from: 17, to: 28, kind: :span},
             %{card: %{title: "Due only"}, from: 22, to: 23, kind: :due}
           ] = bars

    assert Enum.map(tl.unscheduled, & &1.title) == ["Loose"]
    assert tl.later == 1 and tl.earlier == 0

    # Grouping and a day zoom: the span is clipped at the window's start.
    config = %{config | rows: "priority", unit: "day", date: "2030-01-20"}
    tl = Timeline.build(board, config, @today)
    assert tl.window.from == ~D[2030-01-07] and tl.window.days == 35
    assert Enum.map(tl.groups, & &1.label) == ["High", "No priority"]
    [%{bars: [%{from: 3, to: 14, clipped_start: false}]}, _] = tl.groups
    assert tl.window.weekends == [5, 6, 12, 13, 19, 20, 26, 27, 33, 34]

    # A window that starts inside the span clips it.
    tl = Timeline.build(board, %{config | date: "2030-01-24"}, @today)
    assert tl.window.from == ~D[2030-01-14]
    assert [%{bars: [%{from: 0, to: 7, clipped_start: true, clipped_end: false}]} | _] = tl.groups
    assert tl.earlier == 0 and tl.later == 1
  end

  test "Timeline.shift_attrs moves whole cards or one edge", %{span: span, due: due} do
    assert Timeline.shift_attrs(span, "both", 3) == %{
             "start_date" => ~D[2030-01-13],
             "due_date" => ~D[2030-01-23]
           }

    assert Timeline.shift_attrs(span, "start", 2) == %{"start_date" => ~D[2030-01-12]}
    # An edge can't cross the other one.
    assert Timeline.shift_attrs(span, "start", 30) == %{"start_date" => ~D[2030-01-20]}
    assert Timeline.shift_attrs(span, "end", -30) == %{"due_date" => ~D[2030-01-10]}
    # Cards with only a due date grow a start date from it.
    assert Timeline.shift_attrs(due, "start", -4) == %{"start_date" => ~D[2030-01-11]}
    assert Timeline.shift_attrs(due, "both", 1) == %{"due_date" => ~D[2030-01-16]}
    # Pulling the right edge of a due-only pill extends it into a span.
    assert Timeline.shift_attrs(due, "end", 3) == %{
             "start_date" => ~D[2030-01-15],
             "due_date" => ~D[2030-01-18]
           }

    assert Timeline.shift_attrs(due, "end", -3) == %{}
  end

  test "renders, drags, groups and pages", %{conn: conn, board: board, span: span, loose: loose} do
    {:ok, view, _html} = live(conn, ~p"/boards/#{board}/timeline?date=2030-01-15")
    assert has_element?(view, "#timeline")
    assert has_element?(view, "#tl-bar-all-#{span.id}[data-kind=span]")
    assert has_element?(view, "#dateless-#{loose.id}")
    assert has_element?(view, "#swim-nav-title", "Dec 2029 – Apr 2030")

    # Dragging the bar two days to the right moves both dates.
    render_hook(view, "timeline_move", %{"id" => span.id, "edge" => "both", "delta" => 2})
    span = Boards.get_card!(span.id)
    assert span.start_date == ~D[2030-01-12] and span.due_date == ~D[2030-01-22]

    render_hook(view, "timeline_move", %{"id" => span.id, "edge" => "end", "delta" => -1})
    assert Boards.get_card!(span.id).due_date == ~D[2030-01-21]

    # Scheduling from the tray sets a due date and moves the card onto the grid.
    view |> form("#schedule-#{loose.id}", %{"value" => "2030-01-18"}) |> render_change()
    assert Boards.get_card!(loose.id).due_date == ~D[2030-01-18]
    assert has_element?(view, "#tl-bar-all-#{loose.id}[data-kind=due]")

    # Dragging a tray card onto a day column does the same; the day is an
    # index into the window, and out-of-range drops are ignored.
    Boards.update_card(Boards.get_card!(loose.id), %{"due_date" => nil})
    assert has_element?(view, "#dateless-cards[phx-hook=TimelineTray] #dateless-#{loose.id}")
    render_hook(view, "timeline_schedule", %{"id" => loose.id, "day" => 112})
    assert is_nil(Boards.get_card!(loose.id).due_date)
    render_hook(view, "timeline_schedule", %{"id" => loose.id, "day" => 3})
    assert Boards.get_card!(loose.id).due_date == ~D[2029-12-27]
    assert has_element?(view, "#tl-bar-all-#{loose.id}[data-kind=due]")

    # Group by list, zoom to months.
    view |> form("#swim-config", %{"rows" => "column", "unit" => "month"}) |> render_change()
    assert_patch(view, ~p"/boards/#{board}/timeline?date=2030-01-15&rows=column&unit=month")
    assert has_element?(view, "#tl-bar-#{span.column_id}-#{span.id}")

    # Opening a card keeps the timeline URL.
    view |> element("#tl-bar-#{span.column_id}-#{span.id}") |> render_click()

    assert_patch(
      view,
      ~p"/boards/#{board}/timeline/cards/#{span.id}?date=2030-01-15&rows=column&unit=month"
    )

    assert has_element?(view, "#card-modal input[name='card[start_date]']")

    # Paging keeps the other settings and "Today" drops the anchor.
    view |> element("button[phx-value-key=date][title=Later]") |> render_click()
    assert_patch(view, ~p"/boards/#{board}/timeline?date=2030-10-01&rows=column&unit=month")
    view |> element("button[phx-value-key=date][title='Back to today']") |> render_click()
    assert_patch(view, ~p"/boards/#{board}/timeline?rows=column&unit=month")
  end

  test "saved views remember the timeline but not the page", %{conn: conn, board: board} do
    {:ok, view, _} = live(conn, ~p"/boards/#{board}/timeline?rows=tag&date=2030-01-15")
    view |> form("form[phx-submit=swim_save_view]", %{"name" => "Plan"}) |> render_submit()
    [saved] = Boards.list_saved_views(board.id)
    assert saved.config["mode"] == "timeline" and saved.config["rows"] == "tag"
    refute Map.has_key?(saved.config, "date")
    assert_patch(view, ~p"/boards/#{board}/timeline?view=#{saved.id}")

    # Paging a loaded view doesn't mark it modified.
    view |> element("button[phx-value-key=date][title=Later]") |> render_click()
    refute has_element?(view, ".badge", "modified")

    {:ok, table, _} = live(conn, ~p"/boards/#{board}/table")
    assert has_element?(table, "a[href='/boards/#{board.id}/timeline?view=#{saved.id}']", "Plan")
  end

  test "subcards hang beneath their card, or link to their board when cut off" do
    ctx = tree_fixture()
    conn = build_conn() |> log_in_user(user_fixture())

    # The default depth (1) shows no subcard rows or toggle, but links to the
    # sub-board's timeline instead.
    {:ok, view, _} = live(conn, ~p"/boards/#{ctx.board}/timeline?date=2030-01-15")
    assert has_element?(view, "#tl-all-#{ctx.epic.id}[data-level='0']")
    refute has_element?(view, "#tl-all-#{ctx.c.id}")

    refute has_element?(
             view,
             "#tl-all-#{ctx.epic.id} button[phx-value-key='card-#{ctx.epic.id}']"
           )

    assert has_element?(
             view,
             "#tl-all-#{ctx.epic.id} a[href='/boards/#{ctx.sub.id}/timeline'][title^='2 subcards']"
           )

    # Deeper, the rows appear indented and the toggle collapses them.
    {:ok, view, _} = live(conn, ~p"/boards/#{ctx.board}/timeline?date=2030-01-15&depth=all")
    assert has_element?(view, "#tl-all-#{ctx.c.id}[data-level='1']")
    assert has_element?(view, "#tl-all-#{ctx.e.id}[data-level='2']")
    refute has_element?(view, "#tl-all-#{ctx.epic.id} a[href='/boards/#{ctx.sub.id}/timeline']")

    view
    |> element("#tl-all-#{ctx.epic.id} button[phx-value-key='card-#{ctx.epic.id}']")
    |> render_click()

    refute has_element?(view, "#tl-all-#{ctx.c.id}")
    assert has_element?(view, "#tl-all-#{ctx.epic.id}")
  end
end
