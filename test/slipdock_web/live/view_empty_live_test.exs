defmodule SlipdockWeb.ViewEmptyLiveTest do
  @moduledoc """
  Each board view's nothing-to-show block (#2885), through its page: the
  views call `view_empty/1`, and these hold what each one hands it. An empty
  board says so, filters that hide every card offer to clear them, and the
  views that can show cards without drawing any say why in their own line.
  The table's block, with its add row, is in `table_view_live_test.exs`.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.Component, only: [sigil_H: 2]
  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.Swimlanes.Config

  @filtered "No cards match the current filters."
  @none "This board has no cards yet."
  @clear "button[phx-click=swim_clear_filters]"

  # {the page, its block, the conn it mounts on, whether its defaults filter}:
  # the two layouts of a view that stacks on a phone are two call sites, and
  # Prioritise hides done cards by default (`Config.defaults/1`), which is a
  # filter to clear even on an empty board.
  @views [
    {"outline", "#outline-scroll > [data-view-empty=fill]", :desktop, false},
    {"swimlanes", "#swim-scroll > [data-view-empty=fill]", :desktop, false},
    {"swimlanes", "#swim-scroll > [data-view-empty=fill]", :phone, false},
    {"timeline", "#timeline-scroll > [data-view-empty=fill]", :desktop, false},
    {"timeline", "#timeline-scroll > [data-view-empty=fill]", :phone, false},
    {"prioritise", "[data-view-empty=block]", :desktop, true},
    {"calendar", "[data-view-empty=strip]", :desktop, false}
  ]

  defp on(conn, :desktop), do: conn
  defp on(conn, :phone), do: phone(conn)

  for {page, block, device, filters?} <- @views do
    describe "#{page} (#{device})" do
      test "a board with no cards says so, with Clear filters only if the view filters", %{
        conn: conn
      } do
        board = board_fixture()

        {:ok, view, _} = live(on(conn, unquote(device)), "/boards/#{board.id}/#{unquote(page)}")

        assert has_element?(view, unquote(block), @none)
        refute has_element?(view, unquote(block), @filtered)
        assert has_element?(view, "#{unquote(block)} #{@clear}") == unquote(filters?)
        assert [_one] = view |> render() |> LazyHTML.from_fragment() |> all("[data-view-empty]")
      end

      test "filters that hide every card say so and clear from the block", %{conn: conn} do
        board = board_fixture()
        card_fixture(hd(board.columns), %{"title" => "Hidden by the search"})

        {:ok, view, _} =
          live(on(conn, unquote(device)), "/boards/#{board.id}/#{unquote(page)}?q=no-such-card")

        assert has_element?(view, unquote(block), @filtered)
        refute has_element?(view, unquote(block), @none)

        view |> element("#{unquote(block)} #{@clear}") |> render_click()
        refute render(view) =~ @filtered
      end
    end
  end

  defp all(html, selector), do: html |> LazyHTML.query(selector) |> Enum.to_list()

  describe "the views that draw an icon" do
    test "each has its own", %{conn: conn} do
      board = board_fixture()

      for {page, icon} <- [
            {"outline", "hero-queue-list"},
            {"swimlanes", "hero-table-cells"},
            {"timeline", "hero-chart-bar"},
            {"prioritise", "hero-scale"}
          ] do
        {:ok, view, _} = live(conn, "/boards/#{board.id}/#{page}")
        assert has_element?(view, "[data-view-empty] .#{icon}.size-10"), page
      end

      {:ok, view, _} = live(conn, "/boards/#{board.id}/calendar")
      refute has_element?(view, "[data-view-empty] [class*=hero-]")
    end
  end

  describe "the timeline's own line" do
    for device <- [:desktop, :phone] do
      test "cards shown, none scheduled in the range (#{device})", %{conn: conn} do
        board = board_fixture()

        card_fixture(hd(board.columns), %{
          "title" => "Long ago",
          "start_date" => "2020-01-06",
          "due_date" => "2020-01-08"
        })

        {:ok, view, _} =
          live(
            on(conn, unquote(device)),
            "/boards/#{board.id}/timeline?date=2030-01-15&empty=hide"
          )

        block = "#timeline-scroll > [data-view-empty=fill]"
        assert has_element?(view, block, "Nothing is scheduled in this range")
        assert has_element?(view, block, "1 earlier")
        refute has_element?(view, block, "later")
        refute has_element?(view, block, @none)
        refute has_element?(view, block, @filtered)
        refute has_element?(view, "#{block} #{@clear}")
      end
    end
  end

  describe "the swimlanes' own line" do
    for narrow <- [false, true] do
      test "cards shown, no row or column to put them in (narrow: #{narrow})" do
        assigns = %{
          board: %Slipdock.Boards.Board{id: 1, columns: []},
          grid: %{rows: [], cols: [], shown: 2, hidden: 1},
          config: %Config{q: "parser"},
          narrow: unquote(narrow)
        }

        html =
          rendered_to_string(~H"""
          <SlipdockWeb.SwimlaneComponents.swim_grid
            board={@board}
            grid={@grid}
            config={@config}
            collapsed={MapSet.new()}
            form_key={0}
            narrow={@narrow}
          />
          """)

        block = html |> LazyHTML.from_fragment() |> LazyHTML.query("[data-view-empty=fill]")
        assert LazyHTML.text(block) =~ "Nothing to show on these axes."
        refute html =~ @filtered
        refute html =~ @none
        assert [_one] = all(block, @clear)
      end
    end
  end

  describe "the narrative" do
    test "an empty board has no note: the page says it its own way", %{conn: conn} do
      board = board_fixture()
      {:ok, view, _} = live(conn, "/boards/#{board.id}/narrative")
      refute has_element?(view, "[data-view-empty]")
    end

    test "filters that hide every card: a note in the header, with a small button", %{
      conn: conn
    } do
      board = board_fixture()
      card_fixture(hd(board.columns), %{"title" => "Hidden by the search"})

      {:ok, view, _} = live(conn, "/boards/#{board.id}/narrative?q=no-such-card")

      assert has_element?(view, "header [data-view-empty=inline]", @filtered)
      refute has_element?(view, "[data-view-empty] p")

      view |> element("[data-view-empty=inline] #{@clear}.btn-xs") |> render_click()
      refute has_element?(view, "[data-view-empty]")
    end
  end

  describe "the table stacked on a phone" do
    test "filters that hide every card say so and clear from the block", %{conn: conn} do
      board = board_fixture()
      card_fixture(hd(board.columns), %{"title" => "Hidden by the search"})

      {:ok, view, _} = live(phone(conn), "/boards/#{board.id}/table?q=no-such-card")

      block = "#table-scroll > [data-view-empty=fill]"
      assert has_element?(view, block, @filtered)
      refute has_element?(view, block, @none)
      assert has_element?(view, "#{block} .hero-table-cells.size-10")
      refute has_element?(view, "form#table-add")

      view |> element("#{block} #{@clear}") |> render_click()
      assert has_element?(view, "#card-table", "Hidden by the search")
    end
  end

  describe "the calendar's strip" do
    test "is gone once a card is shown", %{conn: conn} do
      board = board_fixture()
      card_fixture(hd(board.columns), %{"title" => "Here"})

      {:ok, view, _} = live(conn, "/boards/#{board.id}/calendar")
      refute has_element?(view, "[data-view-empty]")
    end
  end
end
