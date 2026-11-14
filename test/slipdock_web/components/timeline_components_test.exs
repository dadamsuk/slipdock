defmodule SlipdockWeb.TimelineComponentsTest do
  # Where a timeline bar's title goes, the title column's resize handle and
  # the Unscheduled tray's place (#1732).
  use Slipdock.DataCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.Swimlanes.Config
  alias Slipdock.Timeline
  alias SlipdockWeb.TimelineComponents

  @today ~D[2030-01-15]

  # A week-zoom window: 112 days of 14px from 2029-12-24.
  @window %{days: 112, px: 14}

  defp bar(title, from, to, opts \\ []) do
    %{
      card: %{title: title},
      from: from,
      to: to,
      kind: Keyword.get(opts, :kind, :span),
      clipped_end: Keyword.get(opts, :clipped_end, false),
      derived_start: Keyword.get(opts, :derived, false),
      derived_end: false
    }
  end

  describe "label_place/2" do
    test "a title that fits stays inside its bar" do
      assert TimelineComponents.label_place(bar("Wide", 10, 30), @window) ==
               %{side: :inside, max: nil}
    end

    test "a bar too short for its title has it beside, on the right" do
      assert TimelineComponents.label_place(bar("Write the release notes", 10, 12), @window) ==
               %{side: :right, max: nil}
    end

    test "a due-only or start-only bar never holds its title, however short" do
      for kind <- [:due, :start] do
        assert %{side: :right} =
                 TimelineComponents.label_place(bar("A", 10, 11, kind: kind), @window)
      end
    end

    test "clipped at the right edge, or too close to it, the title goes on the left" do
      clipped = bar("Runs past the edge", 107, 112, clipped_end: true)
      assert TimelineComponents.label_place(clipped, @window) == %{side: :left, max: nil}

      near = bar("Near the edge card", 109, 111)
      assert TimelineComponents.label_place(near, @window) == %{side: :left, max: nil}
    end

    test "with room on neither side, the roomier side gets what fits" do
      title = String.duplicate("x", 40)
      # 40 characters is about 260px, more than either side of these bars has.
      squeezed = %{days: 30, px: 10}

      assert %{side: :left, max: 144} =
               TimelineComponents.label_place(bar(title, 15, 16), squeezed)

      assert %{side: :right, max: 194} =
               TimelineComponents.label_place(bar(title, 1, 10), squeezed)
    end

    test "a span with almost no room either side keeps its title inside, cut short" do
      assert %{side: :inside} =
               TimelineComponents.label_place(bar("A long title here", 1, 4), %{days: 8, px: 10})
    end

    test "a due-only pill with no room either side still has its title beside, at the least width" do
      assert %{side: :right, max: 48} =
               TimelineComponents.label_place(
                 bar("A long title here", 1, 2, kind: :due),
                 %{days: 3, px: 10}
               )
    end

    test "a bar showing the rolled-up icon needs room for it too" do
      # "Abcdefghij" is 65px; a 6-day bar has 84 - 2 - 14 = 68px inside.
      assert %{side: :inside} = TimelineComponents.label_place(bar("Abcdefghij", 10, 16), @window)

      assert %{side: :right} =
               TimelineComponents.label_place(bar("Abcdefghij", 10, 16, derived: true), @window)
    end
  end

  describe "timeline_view/1" do
    setup do
      board = board_fixture(%{"name" => "Labels", "code" => "tlabels"})
      [list | _] = board.columns

      card = fn title, attrs -> card_fixture(list, Map.put(attrs, "title", title)) end
      card.("Wide bar", %{"start_date" => "2030-01-01", "due_date" => "2030-01-20"})

      card.("Write the release notes", %{"start_date" => "2030-01-10", "due_date" => "2030-01-11"})

      card.("Ship it", %{"due_date" => "2030-01-25"})
      card.("Runs past the edge", %{"start_date" => "2030-04-10", "due_date" => "2030-05-30"})
      done = card.("Finished thing", %{"start_date" => "2030-01-02", "due_date" => "2030-01-20"})
      {:ok, _} = Slipdock.Boards.Cards.update_card(done, %{"completed" => true})
      card.("Undated", %{})

      %{board: Slipdock.Boards.get_board!(board.id)}
    end

    defp render_timeline(board) do
      config = %{Config.defaults("timeline") | date: "2030-01-15", unit: "week"}

      html =
        render_component(&TimelineComponents.timeline_view/1,
          board: board,
          config: config,
          timeline: Timeline.build(board, config, @today),
          collapsed: MapSet.new()
        )

      {:ok, doc} = Floki.parse_fragment(html)
      doc
    end

    defp bar_classes(doc, title) do
      doc
      |> Floki.find(".tl-bar")
      |> Enum.find(&(Floki.find(&1, ".tl-bar-label") |> Floki.text() |> String.trim() == title))
      |> Floki.attribute("class")
      |> hd()
      |> String.split()
    end

    test "wide, narrow, due-only and clipped-at-edge bars each put the title where it fits",
         %{board: board} do
      doc = render_timeline(board)

      wide = bar_classes(doc, "Wide bar")
      refute "tl-label-out" in wide

      narrow = bar_classes(doc, "Write the release notes")
      assert "tl-label-out" in narrow and "tl-label-right" in narrow

      due = bar_classes(doc, "Ship it")
      assert "tl-bar-due" in due and "tl-label-right" in due

      clipped = bar_classes(doc, "Runs past the edge")
      assert "tl-clip-end" in clipped and "tl-label-left" in clipped

      # None is cut short: no max-width on any label.
      refute doc
             |> Floki.find(".tl-bar-label")
             |> Floki.attribute("style")
             |> Enum.any?(&(&1 =~ "max-width"))
    end

    test "a bar's tooltip writes its dates with weekday and year (#2880)", %{board: board} do
      titles =
        board
        |> render_timeline()
        |> Floki.find("[title]")
        |> Floki.attribute("title")

      assert "Wide bar\nTue 1 Jan 2030 → Sun 20 Jan 2030" in titles
      assert "Ship it\nDue Fri 25 Jan 2030" in titles
    end

    test "a title too long for either side is cut to the roomier side's width" do
      board = board_fixture(%{"name" => "Long", "code" => "tllong"})
      [list | _] = board.columns
      title = String.duplicate("Long words ", 16) |> String.trim()

      card_fixture(list, %{
        "title" => title,
        "start_date" => "2030-02-20",
        "due_date" => "2030-02-21"
      })

      doc = render_timeline(Slipdock.Boards.get_board!(board.id))

      # From 2029-12-24 the bar is days 58 to 60 of 112: 52 days (722px) right, 58 (806px) left.
      assert "tl-label-left" in bar_classes(doc, title)
      assert [style] = doc |> Floki.find(".tl-bar-label") |> Floki.attribute("style")
      assert style =~ "max-width: 806px"
    end

    test "the title column has a resize handle and reads its width from <html>",
         %{board: board} do
      doc = render_timeline(board)

      assert [handle] = Floki.find(doc, "#tl-resize[phx-hook=TimelineLabelResize]")
      assert Floki.attribute(handle, "role") == ["separator"]

      [style] = doc |> Floki.find("#timeline") |> Floki.attribute("style")
      assert style =~ "--tl-cols: var(--tl-label-width, 16rem) var(--tl-track)"
    end

    test "the scroll box is only as tall as its rows, so the tray follows them",
         %{board: board} do
      doc = render_timeline(board)

      [class] = doc |> Floki.find("#timeline-scroll") |> Floki.attribute("class")
      assert "shrink" in String.split(class)
      refute "flex-1" in String.split(class)
      assert [_] = Floki.find(doc, "#dateless-cards")
    end

    test "with nothing on the grid, the empty state still fills the window" do
      board = board_fixture(%{"name" => "Empty", "code" => "tlempty"})
      doc = render_timeline(Slipdock.Boards.get_board!(board.id))

      [class] = doc |> Floki.find("#timeline-scroll") |> Floki.attribute("class")
      assert "flex-1" in String.split(class)
      assert Floki.find(doc, "#tl-resize") == []
    end

    test "a done card's row is dimmed without an opacity on the row itself", %{board: board} do
      doc = render_timeline(board)

      [row] =
        doc
        |> Floki.find(".tl-card-row")
        |> Enum.filter(&(Floki.text(&1) =~ "Finished thing"))

      [class] = Floki.attribute(row, "class")
      assert "tl-row-dim" in String.split(class)
      refute class =~ "opacity-"
    end
  end
end
