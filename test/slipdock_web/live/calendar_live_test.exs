defmodule SlipdockWeb.CalendarLiveTest do
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures
  alias Slipdock.Boards
  alias Slipdock.Calendar
  alias Slipdock.Swimlanes.Config

  @today ~D[2030-01-15]

  setup do
    board = board_fixture(%{"name" => "Dated"})
    [backlog, todo | _] = board.columns

    span =
      card_fixture(backlog, %{
        "title" => "Span",
        "start_date" => "2030-01-10",
        "due_date" => "2030-01-20"
      })

    due = card_fixture(todo, %{"title" => "Due only", "due_date" => "2030-01-15"})
    loose = card_fixture(todo, %{"title" => "Loose"})
    %{board: reload(board), span: span, due: due, loose: loose}
  end

  test "Calendar.build lays out a month or a week", %{board: board} do
    config = %{Config.defaults("calendar") | date: "2030-01-15"}
    cal = Calendar.build(board, config, @today)

    assert cal.unit == "month" and cal.title == "January 2030"
    assert length(cal.weeks) == 5
    assert hd(hd(cal.weeks)).date == ~D[2029-12-31]
    refute hd(hd(cal.weeks)).in_period?
    assert cal.weekdays == ~w(Mon Tue Wed Thu Fri Sat Sun)
    assert cal.prev == "2029-12-01" and cal.next == "2030-02-01"

    days = List.flatten(cal.weeks)

    assert %{today?: true, cards: [%{title: "Due only"}]} =
             Enum.find(days, &(&1.key == "2030-01-15"))

    assert %{cards: [%{title: "Span"}]} = Enum.find(days, &(&1.key == "2030-01-20"))
    assert Enum.map(cal.undated, & &1.title) == ["Loose"]
    assert cal.elsewhere == 0

    week = Calendar.build(board, %{config | unit: "week", date: "2030-01-22"}, @today)
    assert week.unit == "week" and week.title == "21 – 27 January 2030"
    assert [[%{date: ~D[2030-01-21]} | _]] = week.weeks
    assert week.prev == "2030-01-14" and week.next == "2030-01-28"
    assert week.elsewhere == 2
  end

  test "Calendar.move_attrs keeps a card's duration", %{span: span, due: due, loose: loose} do
    assert Calendar.move_attrs(span, ~D[2030-01-25]) == %{
             "start_date" => ~D[2030-01-15],
             "due_date" => ~D[2030-01-25]
           }

    assert Calendar.move_attrs(due, ~D[2030-01-01]) == %{"due_date" => ~D[2030-01-01]}
    assert Calendar.move_attrs(loose, ~D[2030-01-01]) == %{"due_date" => ~D[2030-01-01]}
  end

  test "renders, drags between days, quick adds and pages", %{
    conn: conn,
    board: board,
    span: span,
    due: due,
    loose: loose
  } do
    {:ok, view, _html} = live(conn, ~p"/boards/#{board}/calendar?date=2030-01-15")
    assert has_element?(view, "#calendar")
    assert has_element?(view, "#swim-nav-title", "January 2030")
    assert has_element?(view, "#cal-2030-01-15-#{due.id}")
    assert has_element?(view, "#cal-2030-01-20-#{span.id}")
    assert has_element?(view, "#dateless-#{loose.id}")

    # Drop the span five days later: it keeps its length.
    render_hook(view, "cal_move", %{
      "id" => span.id,
      "from" => "2030-01-20",
      "to" => "2030-01-25",
      "before" => nil
    })

    span = Boards.get_card!(span.id)
    assert span.start_date == ~D[2030-01-15] and span.due_date == ~D[2030-01-25]
    assert has_element?(view, "#cal-2030-01-25-#{span.id}")

    # Drop an undated card on a day, and a dated card back into the tray.
    render_hook(view, "cal_move", %{"id" => loose.id, "from" => "none", "to" => "2030-01-03"})
    assert Boards.get_card!(loose.id).due_date == ~D[2030-01-03]
    render_hook(view, "cal_move", %{"id" => due.id, "from" => "2030-01-15", "to" => "none"})
    assert is_nil(Boards.get_card!(due.id).due_date)
    assert has_element?(view, "#dateless-#{due.id}")

    # Quick add on a day.
    view |> element("#cal-day-2030-01-16 button[phx-click=swim_start_add]") |> render_click()
    view |> form("form[id^=cal-add-2030-01-16]", %{"title" => "Standup"}) |> render_submit()

    new =
      board
      |> reload()
      |> Map.get(:columns)
      |> Enum.flat_map(& &1.cards)
      |> Enum.find(&(&1.title == "Standup"))

    assert new.due_date == ~D[2030-01-16]
    assert has_element?(view, "#cal-2030-01-16-#{new.id}")

    # Week span and paging.
    view |> form("#swim-config", %{"unit" => "week"}) |> render_change()
    assert_patch(view, ~p"/boards/#{board}/calendar?date=2030-01-15&unit=week")
    assert has_element?(view, "#swim-nav-title", "14 – 20 January 2030")
    view |> element("button[phx-value-key=date][title=Earlier]") |> render_click()
    assert_patch(view, ~p"/boards/#{board}/calendar?date=2030-01-07&unit=week")

    view |> element("button[phx-value-key=date][title=Later]") |> render_click()
    assert_patch(view, ~p"/boards/#{board}/calendar?date=2030-01-14&unit=week")

    # Opening a card keeps the calendar URL.
    view |> element("#cal-2030-01-16-#{new.id}") |> render_click()
    assert_patch(view, ~p"/boards/#{board}/calendar/cards/#{new.id}?date=2030-01-14&unit=week")
    assert has_element?(view, "#card-modal")
  end

  test "cards can be placed on their start date instead", %{
    conn: conn,
    board: board,
    span: span,
    due: due,
    loose: loose
  } do
    config = %{Config.defaults("calendar") | date: "2030-01-15", place: "start"}
    cal = Calendar.build(board, config, @today)
    days = List.flatten(cal.weeks)
    assert cal.place == "start"
    assert %{cards: [%{title: "Span"}]} = Enum.find(days, &(&1.key == "2030-01-10"))
    assert %{cards: []} = Enum.find(days, &(&1.key == "2030-01-20"))
    assert %{cards: [%{title: "Due only"}]} = Enum.find(days, &(&1.key == "2030-01-15"))

    assert Calendar.move_attrs(span, ~D[2030-01-12], "start") == %{
             "start_date" => ~D[2030-01-12],
             "due_date" => ~D[2030-01-22]
           }

    assert Calendar.move_attrs(due, ~D[2030-01-10], "start") == %{"start_date" => ~D[2030-01-10]}

    assert Calendar.move_attrs(due, ~D[2030-01-20], "start") == %{
             "start_date" => ~D[2030-01-20],
             "due_date" => ~D[2030-01-20]
           }

    assert Calendar.move_attrs(loose, ~D[2030-01-01], "start") == %{
             "start_date" => ~D[2030-01-01]
           }

    {:ok, view, _} = live(conn, ~p"/boards/#{board}/calendar?date=2030-01-15")
    view |> form("#swim-config", %{"place" => "start"}) |> render_change()
    assert_patch(view, ~p"/boards/#{board}/calendar?date=2030-01-15&place=start")
    assert has_element?(view, "#cal-2030-01-10-#{span.id}")
    refute has_element?(view, "#cal-2030-01-20-#{span.id}")

    render_hook(view, "cal_move", %{"id" => loose.id, "from" => "none", "to" => "2030-01-03"})
    loose = Boards.get_card!(loose.id)
    assert loose.start_date == ~D[2030-01-03] and is_nil(loose.due_date)

    view |> element("#cal-day-2030-01-16 button[phx-click=swim_start_add]") |> render_click()
    view |> form("form[id^=cal-add-2030-01-16]", %{"title" => "Kickoff"}) |> render_submit()

    new =
      board
      |> reload()
      |> Map.get(:columns)
      |> Enum.flat_map(& &1.cards)
      |> Enum.find(&(&1.title == "Kickoff"))

    assert new.start_date == ~D[2030-01-16] and is_nil(new.due_date)
    assert has_element?(view, "#cal-2030-01-16-#{new.id}")
  end

  test "saved views remember the calendar mode", %{conn: conn, board: board} do
    {:ok, view, _} = live(conn, ~p"/boards/#{board}/calendar?unit=week&done=hide&date=2030-01-15")
    view |> form("form[phx-submit=swim_save_view]", %{"name" => "This week"}) |> render_submit()
    [saved] = Boards.list_saved_views(board.id)
    assert saved.config["mode"] == "calendar" and saved.config["unit"] == "week"
    assert saved.config["done"] == "hide"
    refute Map.has_key?(saved.config, "date")
    assert_patch(view, ~p"/boards/#{board}/calendar?view=#{saved.id}")

    {:ok, swim, _} = live(conn, ~p"/boards/#{board}/swimlanes")

    assert has_element?(
             swim,
             "a[href='/boards/#{board.id}/calendar?view=#{saved.id}']",
             "This week"
           )
  end
end
