defmodule SlipdockWeb.Components.PriorityStartTest do
  @moduledoc """
  Priority and dates you can read (#1709). Priority draws as one icon
  family, signal bars, with a tooltip naming it, on the card face, the
  outline, the table, the calendar and the filter menu. Medium is left off
  the card face, the outline and the calendar. The start chip's tooltip,
  the start overrun chip and the card back say in words when a card starts,
  and the start and due icons are one pair on the face, the filter menu and
  the card back. tools/e2e/priority-start.sh checks it in a browser.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias SlipdockWeb.SlipdockComponents

  @levels %{"low" => 1, "medium" => 2, "high" => 3, "critical" => 4}
  @labels %{"low" => "Low", "medium" => "Medium", "high" => "High", "critical" => "Critical"}

  setup %{user: user} do
    board = board_fixture(%{"name" => "Signals", "code" => "prs1709"}, owner: user)
    [todo | _] = board.columns
    %{board: board, todo: todo}
  end

  defp days(n), do: Date.utc_today() |> Date.add(n)
  defp iso(n), do: n |> days() |> Date.to_iso8601()

  defp doc(html), do: LazyHTML.from_document(html)
  defp q(node, selector), do: LazyHTML.query(node, selector)
  defp count(node, selector), do: node |> q(selector) |> Enum.count()
  defp attr(node, selector, name), do: node |> q(selector) |> LazyHTML.attribute(name)

  defp badge(priority, extra \\ []) do
    render_component(&SlipdockComponents.priority_badge/1, [priority: priority] ++ extra)
    |> LazyHTML.from_fragment()
  end

  # A bare card map, as the components take it: no subcards unless a rollup is given.
  defp card(attrs) do
    Map.merge(
      %{start_date: nil, due_date: nil, completed: false, rollup: nil, sub_board: nil},
      Map.new(attrs)
    )
  end

  # A card whose subcards begin `slip` days after its own start, on `begins`.
  defp slipped(start, begins, slip, attrs \\ []) do
    card(
      [
        start_date: start,
        rollup: %{
          start: start,
          start_derived?: false,
          derived_start: begins,
          start_slip: slip,
          due_slip: 0,
          derived_due: nil
        }
      ] ++ attrs
    )
  end

  describe "priority_badge/1 draws signal bars" do
    test "every priority: its level of bars lit, its colour, and a tooltip naming it" do
      for {priority, level} <- @levels do
        node = badge(priority)
        label = @labels[priority]

        assert attr(node, "[data-role=priority]", "title") == ["Priority: #{label}"]
        assert attr(node, "[data-role=priority]", "aria-label") == ["Priority: #{label}"]
        assert attr(node, "[data-role=priority]", "role") == ["img"]
        assert attr(node, "[data-role=priority-bars]", "data-level") == [to_string(level)]

        # Four bars always, so the empty ones show how high it could go.
        assert count(node, "[data-role=priority-bars] rect") == 4
        assert count(node, "rect[data-lit=true]") == level
        assert count(node, "rect[data-lit=false]") == 4 - level

        # One family: no heroicon is drawn for any priority.
        assert count(node, "[class*=hero-]") == 0
        refute LazyHTML.text(node) =~ label
      end
    end

    test "the levels rise one bar at a time, low to critical" do
      levels = Enum.map(~w(none low medium high critical), &SlipdockComponents.priority_level/1)
      assert levels == [0, 1, 2, 3, 4]
    end

    test "each priority has its own colour" do
      colours =
        for p <- Map.keys(@levels) do
          node = badge(p)
          [class] = attr(node, "[data-role=priority]", "class")
          class |> String.split() |> Enum.find(&String.starts_with?(&1, "text-"))
        end

      assert length(Enum.uniq(colours)) == 4
    end

    test "with_label adds the name beside the bars" do
      node = badge("critical", with_label: true)
      assert LazyHTML.text(node) =~ "Critical"
      assert count(node, "rect[data-lit=true]") == 4

      refute "chip-icon" in (attr(node, "[data-role=priority]", "class")
                             |> hd()
                             |> String.split())
    end

    test "no priority, nil, or a value it doesn't know draws nothing" do
      for p <- ["none", nil, "urgent", ""] do
        html = render_component(&SlipdockComponents.priority_badge/1, priority: p)
        refute html =~ "priority-bars", "#{inspect(p)} should draw no bars"
        assert String.trim(html) == ""
      end

      assert render_component(&SlipdockComponents.priority_badge/1,
               priority: "none",
               with_label: true
             ) =~ "No priority"

      assert SlipdockComponents.priority_level("urgent") == 0
      assert SlipdockComponents.priority_level(nil) == 0
    end

    test "priority_on_face? leaves out medium, none and anything unknown" do
      assert Enum.filter(~w(none low medium high critical urgent), fn p ->
               SlipdockComponents.priority_on_face?(p)
             end) == ~w(low high critical)

      refute SlipdockComponents.priority_on_face?(nil)
    end
  end

  describe "the same bars in every view" do
    setup ctx do
      cards =
        for p <- ~w(low medium high critical), into: %{} do
          {p,
           card_fixture(ctx.todo, %{
             "title" => "Prio #{p}",
             "priority" => p,
             "due_date" => iso(0)
           })}
        end

      Map.put(ctx, :cards, cards)
    end

    test "the card face: bars with a tooltip, and no medium", ctx do
      {:ok, _view, html} = live(ctx.conn, ~p"/boards/#{ctx.board}")

      for {p, card} <- ctx.cards do
        node = doc(html) |> q("#card-#{card.id}")

        if p == "medium" do
          assert count(node, "[data-role=priority]") == 0
        else
          assert attr(node, "[data-role=priority]", "title") == ["Priority: #{@labels[p]}"]
          assert attr(node, "[data-role=priority-bars]", "data-level") == ["#{@levels[p]}"]
        end
      end
    end

    test "the compact card face leaves medium off too", ctx do
      {:ok, _view, html} = live(ctx.conn, ~p"/boards/#{ctx.board}?density=compact")

      assert count(doc(html) |> q("#card-#{ctx.cards["medium"].id}"), "[data-role=priority]") ==
               0

      assert count(doc(html) |> q("#card-#{ctx.cards["high"].id}"), "[data-role=priority]") == 1
    end

    test "the calendar: bars with a tooltip, and no medium", ctx do
      {:ok, _view, html} = live(ctx.conn, ~p"/boards/#{ctx.board}/calendar")

      for {p, card} <- ctx.cards do
        node = doc(html) |> q(".cal-chip[data-id='#{card.id}']")
        refute Enum.empty?(node), "#{p} card should be on the calendar"

        if p == "medium" do
          assert count(node, "[data-role=priority]") == 0
        else
          assert "Priority: #{@labels[p]}" in attr(node, "[data-role=priority]", "title")
          assert "#{@levels[p]}" in attr(node, "[data-role=priority-bars]", "data-level")
        end
      end
    end

    test "the calendar chip's tooltip names the priority, bar medium" do
      title = fn p ->
        SlipdockWeb.CalendarComponents.chip_title(%{
          title: "T",
          start_date: nil,
          due_date: nil,
          completed: false,
          priority: p,
          flags: [],
          tags: []
        })
      end

      assert title.("high") =~ "Priority: High"
      assert title.("low") =~ "Priority: Low"
      refute title.("medium") =~ "Priority"
      refute title.("none") =~ "Priority"
      refute title.(nil) =~ "Priority"
    end

    test "the calendar chip's tooltip writes its dates with weekday and year (#2880)" do
      title = fn start, due ->
        SlipdockWeb.CalendarComponents.chip_title(%{
          title: "T",
          start_date: start,
          due_date: due,
          completed: false,
          priority: "none",
          flags: [],
          tags: []
        })
      end

      assert title.(~D[2030-01-01], ~D[2030-01-20]) == "T\nTue 1 Jan 2030 → Sun 20 Jan 2030"
      assert title.(nil, ~D[2030-01-25]) == "T\nDue Fri 25 Jan 2030"
      assert title.(~D[2030-01-01], nil) == "T\nStarts Tue 1 Jan 2030"
      assert title.(nil, nil) == "T\nNo date"
    end

    test "the outline: bars with a tooltip, and no medium", ctx do
      {:ok, _view, html} = live(ctx.conn, ~p"/boards/#{ctx.board}/outline")

      for {p, card} <- ctx.cards do
        node = doc(html) |> q("#ol-#{card.id}")
        assert Enum.count(node) == 1, "#{p} card should be in the outline"

        if p == "medium" do
          assert count(node, "[data-role=priority]") == 0
        else
          assert attr(node, "[data-role=priority]", "title") == ["Priority: #{@labels[p]}"]
          assert attr(node, "[data-role=priority-bars]", "data-level") == ["#{@levels[p]}"]
        end
      end
    end

    test "the table: bars beside every priority, medium included", ctx do
      {:ok, _view, html} = live(ctx.conn, ~p"/boards/#{ctx.board}/table")
      root = doc(html)

      for {p, card} <- ctx.cards do
        node = q(root, "#prio-#{card.id}")
        assert attr(node, "[data-role=priority]", "title") == ["Priority: #{@labels[p]}"]
        assert attr(node, "[data-role=priority-bars]", "data-level") == ["#{@levels[p]}"]
        assert attr(node, "option[selected]", "value") == [p]
      end
    end

    test "the table: a card with no priority has no bars", ctx do
      none = card_fixture(ctx.todo, %{"title" => "Unranked", "priority" => "none"})
      {:ok, _view, html} = live(ctx.conn, ~p"/boards/#{ctx.board}/table")
      node = doc(html) |> q("#prio-#{none.id}")
      assert Enum.count(node) == 1
      assert count(node, "[data-role=priority]") == 0
    end

    test "the filter menu: every priority, medium included, as bars", ctx do
      {:ok, _view, html} = live(ctx.conn, ~p"/boards/#{ctx.board}")
      menu = doc(html) |> q("[data-role=filter-priority]")

      assert attr(menu, "[data-role=priority]", "data-priority") == ~w(low medium high critical)
      assert attr(menu, "[data-role=priority-bars]", "data-level") == ~w(1 2 3 4)

      assert attr(menu, "[data-role=priority]", "title") ==
               Enum.map(~w(Low Medium High Critical), &"Priority: #{&1}")
    end
  end

  describe "start_words/2" do
    @today ~D[2030-06-15]

    test "early: a start still to come counts the days to it" do
      assert SlipdockComponents.start_words(card(start_date: ~D[2030-06-26]), @today) ==
               "Starts in 11 days"

      assert SlipdockComponents.start_words(card(start_date: ~D[2030-06-17]), @today) ==
               "Starts in 2 days"

      assert SlipdockComponents.start_words(card(start_date: ~D[2030-06-16]), @today) ==
               "Starts tomorrow"
    end

    test "on time: a start of today" do
      assert SlipdockComponents.start_words(card(start_date: @today), @today) == "Starts today"
    end

    test "a start that has passed, on time, counts back to it" do
      assert SlipdockComponents.start_words(card(start_date: ~D[2030-06-14]), @today) ==
               "Started yesterday"

      assert SlipdockComponents.start_words(card(start_date: ~D[2030-06-04]), @today) ==
               "Started 11 days ago"
    end

    test "late: subcards that began after the card's start say how late" do
      card = slipped(~D[2030-06-01], ~D[2030-06-12], 11)
      assert SlipdockComponents.start_words(card, @today) == "Started 11 days late"

      # Beginning today counts as started.
      card = slipped(~D[2030-06-04], @today, 11)
      assert SlipdockComponents.start_words(card, @today) == "Started 11 days late"

      card = slipped(~D[2030-06-14], ~D[2030-06-15], 1)
      assert SlipdockComponents.start_words(card, @today) == "Started 1 day late"
    end

    test "late, and still to begin: starts N days late" do
      card = slipped(~D[2030-06-10], ~D[2030-06-21], 11)
      assert SlipdockComponents.start_words(card, @today) == "Starts 11 days late"
    end

    test "a completed card is never late" do
      card = slipped(~D[2030-06-01], ~D[2030-06-12], 11, completed: true)
      assert SlipdockComponents.start_words(card, @today) == "Started 14 days ago"
    end

    test "a start rolled up from subcards counts the same way" do
      card =
        card(
          rollup: %{
            start: ~D[2030-06-20],
            start_derived?: true,
            derived_start: ~D[2030-06-20],
            start_slip: 0
          }
        )

      assert SlipdockComponents.start_words(card, @today) == "Starts in 5 days"
    end

    test "no start date: nil" do
      assert SlipdockComponents.start_words(card([]), @today) == nil
    end

    test "defaults to today" do
      assert SlipdockComponents.start_words(card(start_date: Date.utc_today())) == "Starts today"
    end
  end

  describe "the start chip's tooltip" do
    defp start_title(card) do
      render_component(&SlipdockComponents.start_badge/1, card: card)
      |> LazyHTML.from_fragment()
      |> attr("[data-role=start]", "title")
    end

    test "early: says how many days until it starts, then the date" do
      d = days(11)

      assert start_title(card(start_date: d)) == [
               "Starts in 11 days: " <> SlipdockWeb.Dates.full(d)
             ]
    end

    test "on time: starts today" do
      assert [title] = start_title(card(start_date: days(0)))
      assert title =~ ~r/^Starts today: /
    end

    test "late: started N days late" do
      assert [title] = start_title(slipped(days(-14), days(-3), 11))
      assert title =~ ~r/^Started 11 days late: /
    end

    test "a rolled-up start says so" do
      card =
        card(
          rollup: %{start: days(3), start_derived?: true, derived_start: days(3), start_slip: 0}
        )

      assert [title] = start_title(card)
      assert title =~ ~r/^Starts in 3 days: .* \(rolled up from subcards\)$/
    end

    test "no start date: no chip" do
      html = render_component(&SlipdockComponents.start_badge/1, card: card([]))
      refute html =~ "data-role=\"start\""
    end

    test "draws the start icon, not the play triangle" do
      html = render_component(&SlipdockComponents.start_badge/1, card: card(start_date: days(1)))
      assert html =~ SlipdockComponents.start_icon()
      refute html =~ "hero-play"
    end
  end

  describe "the start overrun chip" do
    test "puts the words before the sentence it already had" do
      card = slipped(days(-14), days(-3), 11)
      html = render_component(&SlipdockComponents.slip_chips/1, card: card)

      assert [title] = html |> LazyHTML.from_fragment() |> attr("[data-role=start-slip]", "title")
      assert title =~ ~r/^Started 11 days late\. Subcards begin .* — 11 days past start date$/
      assert html =~ "start +11d"
    end

    test "is not drawn for a completed card" do
      card = slipped(days(-14), days(-3), 11, completed: true)
      html = render_component(&SlipdockComponents.slip_chips/1, card: card)
      refute html =~ "start-slip"
    end
  end

  describe "the start and due icons are one pair" do
    test "start and due icons are different, and neither is the Waiting flag's clock" do
      assert SlipdockComponents.start_icon() != SlipdockComponents.due_icon()
      refute "hero-clock" in [SlipdockComponents.start_icon(), SlipdockComponents.due_icon()]
      refute SlipdockComponents.start_icon() =~ "play"
    end

    test "the due chip draws the due icon; done and rolled-up dates keep their own" do
      html = render_component(&SlipdockComponents.due_badge/1, date: days(9))
      assert html =~ SlipdockComponents.due_icon()

      html = render_component(&SlipdockComponents.due_badge/1, date: days(9), completed: true)
      assert html =~ "hero-check-circle"

      html = render_component(&SlipdockComponents.due_badge/1, date: days(9), derived: true)
      assert html =~ "hero-arrow-up-on-square-stack"
    end

    test "the face, the filter menu and the card back use the same pair", ctx do
      card =
        card_fixture(ctx.todo, %{
          "title" => "Dated",
          "start_date" => iso(11),
          "due_date" => iso(20)
        })

      {:ok, _view, html} =
        Slipdock.CardViewHelpers.live_showing(
          ctx.conn,
          ctx.user,
          ctx.board,
          ~p"/boards/#{ctx.board}",
          ~w(start_date due_date)
        )

      face = doc(html) |> q("#card-#{card.id}")
      # Both shown, so the face draws them as one range, with the start's words.
      assert [range_title] = attr(face, "[data-role=date-range]", "title")
      assert range_title =~ "Starts"

      {:ok, _view, html} =
        Slipdock.CardViewHelpers.live_showing(
          ctx.conn,
          ctx.user,
          ctx.board,
          ~p"/boards/#{ctx.board}",
          ~w(start_date)
        )

      face = doc(html) |> q("#card-#{card.id}")
      assert count(face, "[data-role=start] .#{SlipdockComponents.start_icon()}") == 1

      {:ok, _view, html} =
        Slipdock.CardViewHelpers.live_showing(
          ctx.conn,
          ctx.user,
          ctx.board,
          ~p"/boards/#{ctx.board}",
          ~w(due_date)
        )

      face = doc(html) |> q("#card-#{card.id}")
      assert count(face, "[title^='Due'] .#{SlipdockComponents.due_icon()}") == 1

      assert count(doc(html), "[data-role=filter-due] .#{SlipdockComponents.due_icon()}") == 1

      {:ok, _view, html} = live(ctx.conn, ~p"/boards/#{ctx.board}/cards/#{card.id}")
      back = doc(html)

      assert count(
               back,
               "[data-prop=start] [data-role=prop-label] .#{SlipdockComponents.start_icon()}"
             ) == 1

      assert count(
               back,
               "[data-prop=due] [data-role=prop-label] .#{SlipdockComponents.due_icon()}"
             ) == 1
    end
  end

  describe "the card back says the start in words" do
    test "early, on time and past", ctx do
      for {n, words} <- [
            {11, "Starts in 11 days"},
            {0, "Starts today"},
            {-3, "Started 3 days ago"}
          ] do
        card = card_fixture(ctx.todo, %{"title" => "Back #{n}", "start_date" => iso(n)})
        {:ok, _view, html} = live(ctx.conn, ~p"/boards/#{ctx.board}/cards/#{card.id}")
        assert doc(html) |> q("[data-role=start-words]") |> LazyHTML.text() =~ words
      end
    end

    test "late: subcards that began after the card's start", ctx do
      parent =
        card_fixture(ctx.todo, %{
          "title" => "Parent",
          "start_date" => iso(-14),
          "due_date" => iso(20)
        })

      {:ok, template} = Slipdock.Boards.Templates.find_template(nil, "Simple")
      {:ok, sub} = sub_board(parent, template)
      [sub_todo | _] = Slipdock.Boards.get_board!(sub.id).columns
      card_fixture(sub_todo, %{"title" => "Child", "start_date" => iso(-3), "due_date" => iso(5)})

      {:ok, _view, html} = live(ctx.conn, ~p"/boards/#{ctx.board}/cards/#{parent.id}")

      assert doc(html) |> q("[data-role=start-words]") |> LazyHTML.text() =~
               "Started 11 days late"
    end

    test "no start date: no words", ctx do
      card = card_fixture(ctx.todo, %{"title" => "Undated"})
      {:ok, _view, html} = live(ctx.conn, ~p"/boards/#{ctx.board}/cards/#{card.id}")
      assert count(doc(html), "[data-role=start-words]") == 0
    end
  end
end
