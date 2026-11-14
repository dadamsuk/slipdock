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

    span = Boards.Cards.get_card!(span.id)
    assert span.start_date == ~D[2030-01-15] and span.due_date == ~D[2030-01-25]
    assert has_element?(view, "#cal-2030-01-25-#{span.id}")

    # Drop an undated card on a day, and a dated card back into the tray.
    render_hook(view, "cal_move", %{"id" => loose.id, "from" => "none", "to" => "2030-01-03"})
    assert Boards.Cards.get_card!(loose.id).due_date == ~D[2030-01-03]
    render_hook(view, "cal_move", %{"id" => due.id, "from" => "2030-01-15", "to" => "none"})
    assert is_nil(Boards.Cards.get_card!(due.id).due_date)
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
    loose = Boards.Cards.get_card!(loose.id)
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
    [saved] = Boards.SavedViews.list_saved_views(board.id)
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

  describe "chips (#1733)" do
    setup %{board: board} do
      [_, todo | _] = board.columns
      title = "Reconcile quarterly invoices with the ledger export"

      long =
        card_fixture(todo, %{
          "title" => title,
          "priority" => "critical",
          "flags" => ["flagged", "blocked"],
          "start_date" => "2030-01-14",
          "due_date" => "2030-01-16"
        })

      for name <- ~w(finance ops audit extra) do
        Boards.Tags.toggle_card_tag(long, tag_fixture(board, name, "rose"))
      end

      %{long: long, title: title}
    end

    test "put the title first and every decoration after it, with no arrow", %{
      conn: conn,
      board: board,
      long: long,
      title: title
    } do
      {:ok, view, _} = live(conn, ~p"/boards/#{board}/calendar?date=2030-01-15")
      chip = "#cal-2030-01-16-#{long.id}"

      assert has_element?(view, "#{chip} > .cal-chip-title:first-child", title)
      # Flags and priority come in first, tags and the done toggle once wider.
      assert has_element?(view, "#{chip} > .cal-deco-1 [title='Flagged']")
      assert has_element?(view, "#{chip} > .cal-deco-1 [title='Blocked']")
      assert has_element?(view, "#{chip} > .cal-deco-1 [title='Priority: Critical']")
      assert has_element?(view, "#{chip} > .cal-deco-2 button[aria-label='Mark complete']")
      # Three tag dots at most.
      html = view |> element("#{chip} > .cal-deco-2") |> render()
      assert length(Regex.scan(~r/size-1\.5 rounded-full/, html)) == 3
      # The start → due arrow did nothing, so it is gone.
      refute render(view) =~ "hero-arrow-long-right"
    end

    test "carry the full title and the metadata in the tooltip", %{
      conn: conn,
      board: board,
      long: long,
      title: title,
      due: due
    } do
      {:ok, view, _} = live(conn, ~p"/boards/#{board}/calendar?date=2030-01-15")

      tip = view |> element("#cal-2030-01-16-#{long.id}") |> render() |> tooltip()
      [first | rest] = String.split(tip, "\n")
      assert first == title
      assert "Priority: Critical" in rest
      assert "Flags: Flagged, Blocked" in rest
      assert "Tags: audit, extra, finance, ops" in rest
      assert Enum.any?(rest, &(&1 =~ "→"))
      refute "Done" in rest

      # A bare card: its title and date, no empty metadata lines, no decorations.
      assert view |> element("#cal-2030-01-15-#{due.id}") |> render() |> tooltip() =~
               ~r/\ADue only\nDue [^\n]+\z/

      refute has_element?(view, "#cal-2030-01-15-#{due.id} .cal-deco-1")
      assert has_element?(view, "#cal-2030-01-15-#{due.id} .cal-deco-2 button")
    end

    test "say a finished card is done, and offer to reopen it", %{conn: conn, board: board} do
      [_, todo | _] = board.columns

      done =
        card_fixture(todo, %{"title" => "Closed", "due_date" => "2030-01-15", "completed" => true})

      {:ok, view, _} = live(conn, ~p"/boards/#{board}/calendar?date=2030-01-15")
      chip = "#cal-2030-01-15-#{done.id}"

      assert view
             |> element(chip)
             |> render()
             |> tooltip()
             |> String.split("\n")
             |> Enum.member?("Done")

      assert has_element?(view, "#{chip} button[aria-label='Mark incomplete']")
    end

    test "let the owner tick a card done, and not a reader (#2886)", %{
      conn: conn,
      board: board,
      due: due
    } do
      path = ~p"/boards/#{board}/calendar?date=2030-01-15"
      toggle = "#cal-2030-01-15-#{due.id} [data-role=complete-toggle]"

      {:ok, view, _} = live(conn, path)
      assert has_element?(view, "#{toggle}:not([disabled])")

      reader = user_fixture("cal.reader@example.com")
      {:ok, _} = Slipdock.Access.grant(board, reader, "read", user_fixture())
      {:ok, view, _} = live(log_in_user(build_conn(), reader), path)
      assert has_element?(view, "#{toggle}[disabled]")
    end

    test "leave out decorations the display turns off, and thin them when compact", %{
      conn: conn,
      board: board,
      long: long,
      title: title
    } do
      {:ok, view, _} =
        Slipdock.CardViewHelpers.live_showing(
          conn,
          Slipdock.Fixtures.user_fixture(),
          board,
          ~p"/boards/#{board}/calendar?date=2030-01-15",
          ~w(status)
        )

      chip = "#cal-2030-01-16-#{long.id}"
      refute has_element?(view, "#{chip} .cal-deco-1")
      assert has_element?(view, "#{chip} .cal-deco-2 button")
      refute has_element?(view, "#{chip} .cal-deco-2 .rounded-full.size-1\\.5")
      # The tooltip keeps the metadata the chip no longer shows.
      assert view |> element(chip) |> render() |> tooltip() =~ "Priority: Critical"

      # Back to the defaults: the card view, not the URL, held the choice.
      {:ok, _} = Slipdock.CardViews.clear_level(Slipdock.Fixtures.user_fixture(), {:board, board})
      {:ok, view, _} = live(conn, ~p"/boards/#{board}/calendar?date=2030-01-15&density=compact")
      assert has_element?(view, "#{chip} > .cal-chip-title:first-child", title)
      assert has_element?(view, "#{chip} .cal-deco-1 [title='Flagged']")
      refute has_element?(view, "#{chip} .cal-deco-1 [title='Blocked']")
      refute has_element?(view, "#{chip} .cal-deco-2")
    end
  end

  test "chip_title copes with a card whose tags and flags are not loaded" do
    card = %{
      title: "Bare",
      start_date: ~D[2030-01-02],
      due_date: nil,
      completed: false,
      priority: nil,
      flags: nil,
      tags: %Ecto.Association.NotLoaded{}
    }

    assert SlipdockWeb.CalendarComponents.chip_title(card) =~ ~r/\ABare\nStarts [^\n]+\z/
    assert SlipdockWeb.CalendarComponents.chip_title(%{card | start_date: nil}) == "Bare\nNo date"
  end

  # The chip's own title attribute (the first in its HTML), unescaped.
  defp tooltip(html) do
    [_, tip] = Regex.run(~r/title="([^"]*)"/, html)

    tip
    |> String.replace("&#10;", "\n")
    |> String.replace("&amp;", "&")
    |> String.replace("&quot;", "\"")
    |> String.replace("&#39;", "'")
  end
end
