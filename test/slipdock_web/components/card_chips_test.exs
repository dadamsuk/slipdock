defmodule SlipdockWeb.Components.CardChipsTest do
  @moduledoc """
  Fewer, quieter chips on the card face (#1708). A board with no saved
  Display settings shows the essentials only: tags, title, assignee, due
  date, priority (not medium), flags, subcard and checklist progress, and
  what blocks the card. Neutral metadata sits in the `card-meta` row as
  plain icon and text (app.css drops a `chip-line` chip's outline there);
  the states that need attention keep a tint. Start and due, both shown,
  draw as one range. tools/e2e/card-chips.sh checks the computed styles in
  a browser.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.Boards
  alias Slipdock.Actor
  alias Slipdock.Swimlanes.Config
  alias SlipdockWeb.SlipdockComponents

  @essentials ~w(cover images status tags priority flags assignee due_date dependencies subcards checklist)

  setup %{user: user} do
    board = board_fixture(%{"name" => "Chips", "code" => "chp1708"}, owner: user)
    [todo, doing | _] = board.columns
    %{board: board, todo: todo, doing: doing, user: user}
  end

  defp days(n), do: Date.utc_today() |> Date.add(n) |> Date.to_iso8601()

  defp card_node(html, card) do
    html |> LazyHTML.from_document() |> LazyHTML.query("#card-#{card.id}")
  end

  defp classes(node, selector) do
    node
    |> LazyHTML.query(selector)
    |> LazyHTML.attribute("class")
    |> Enum.flat_map(&String.split/1)
  end

  defp count(node, selector), do: node |> LazyHTML.query(selector) |> Enum.count()

  describe "the default Display set" do
    test "is the essentials, the same at both densities bar the front image" do
      assert Config.default_show() == @essentials
      assert Config.default_show("normal") == @essentials
      assert Config.default_show("compact") == @essentials -- ["images"]
      assert %Config{}.show == @essentials
      assert %Config{}.show_compact == @essentials -- ["images"]

      for off <- ~w(description age attachments comments start_date percent_complete time) do
        refute off in Config.default_show(), "#{off} should be off by default"
        refute off in Config.default_show("compact"), "#{off} should be off when compact"
      end

      # Every default is a facet the menu offers, so each can be unticked.
      assert @essentials -- Config.facet_keys() == []
    end

    test "every view mode starts from it" do
      for mode <- ~w(board swimlanes table timeline calendar outline narrative prioritise) do
        assert Config.defaults(mode).show == @essentials
      end
    end

    test "a saved view keeps what it stored, and an empty one stays empty" do
      stored = Config.to_map(%Config{show: Config.facet_keys()})
      assert Config.from_map(stored).show == Config.facet_keys()

      assert Config.from_map(%{"show" => []}).show == []
      # A stored map that never had a `show` (a view saved before facets) takes the defaults.
      assert Config.from_map(%{"density" => "compact"}).show == @essentials
      # Unknown facets in a stored view are dropped, not shown.
      assert Config.from_map(%{"show" => ["comments", "bogus"]}).show == ["comments"]
    end

    test "a URL that leaves `show` out encodes nothing for it" do
      refute Keyword.has_key?(Config.to_query(%Config{}), :show)
      assert Config.to_query(%Config{show: ["comments"]}) == [show: "comments"]
    end
  end

  describe "a board with no saved Display settings" do
    test "shows the default set and nothing else", ctx do
      tag = tag_fixture(ctx.board, "Design")

      card =
        card_fixture(ctx.todo, %{
          "title" => "Everything set",
          "priority" => "high",
          "flags" => ["review"],
          "start_date" => days(10),
          "due_date" => days(20),
          "description" => "The long version",
          "percent_complete" => 40
        })

      {:ok, _} = Boards.Cards.set_card_tags(card, [tag])
      {:ok, _} = Boards.Comments.add_comment(card, "A comment", by: ctx.user)

      {:ok, _view, html} = live(ctx.conn, ~p"/boards/#{ctx.board}")
      node = card_node(html, card)

      assert LazyHTML.text(node) =~ "Design"
      assert count(node, "[title^='Priority']") == 1
      assert count(node, "[data-flag=review]") == 1
      assert count(node, "[title^='Due']") == 1

      # Off by default: the start date, the description mark, comments,
      # attachments, % complete and time in list.
      assert count(node, "[title^='Starts']") == 0
      assert count(node, "[title='Has description']") == 0
      assert count(node, "[title='Comments']") == 0
      assert count(node, "[title='Attachments']") == 0
      assert count(node, "[title='40% complete']") == 0
      assert count(node, "[data-role=age-chip]") == 0
      assert count(node, "[data-role=date-range]") == 0
    end

    test "a saved view naming a card view that shows more still shows it", ctx do
      card = card_fixture(ctx.todo, %{"title" => "Talked about"})
      {:ok, _} = Boards.Comments.add_comment(card, "First", by: ctx.user)
      {:ok, _} = Slipdock.CardViews.create(ctx.user, %{"name" => "Busy", "show" => "comments"})

      {:ok, saved} =
        Boards.SavedViews.create_saved_view(ctx.board, %{
          "name" => "Busy",
          "config" => Config.to_map(Config.put_card_view(Config.defaults("board"), "Busy"))
        })

      {:ok, _view, html} = live(ctx.conn, ~p"/boards/#{ctx.board}?view=#{saved.id}")
      assert count(card_node(html, card), "[title='Comments']") == 1

      {:ok, _view, html} = live(ctx.conn, ~p"/boards/#{ctx.board}")
      assert count(card_node(html, card), "[title='Comments']") == 0
    end

    test "compact cards follow the same defaults", ctx do
      card =
        card_fixture(ctx.todo, %{
          "title" => "Compact",
          "priority" => "critical",
          "due_date" => days(20),
          "description" => "Words",
          "percent_complete" => 10
        })

      {:ok, _} = Boards.Comments.add_comment(card, "A comment", by: ctx.user)
      {:ok, _view, html} = live(ctx.conn, ~p"/boards/#{ctx.board}?density=compact")
      node = card_node(html, card)

      assert count(node, "[title^='Priority']") == 1
      assert count(node, "[title^='Due']") == 1
      assert count(node, "[title='Comments']") == 0
      assert count(node, "[title='10% complete']") == 0
      assert count(node, "[data-role=age-chip]") == 0
    end
  end

  describe "priority on the card face" do
    test "shows high, critical and low, and leaves medium and none off", ctx do
      cards =
        for p <- ~w(critical high medium low none),
            into: %{},
            do: {p, card_fixture(ctx.todo, %{"title" => "P #{p}", "priority" => p})}

      {:ok, _view, html} = live(ctx.conn, ~p"/boards/#{ctx.board}")

      for p <- ~w(critical high low),
          do: assert(count(card_node(html, cards[p]), "[title^='Priority']") == 1, p)

      for p <- ~w(medium none),
          do: assert(count(card_node(html, cards[p]), "[title^='Priority']") == 0, p)

      # Compact cards too.
      {:ok, _view, html} = live(ctx.conn, ~p"/boards/#{ctx.board}?density=compact")
      assert count(card_node(html, cards["medium"]), "[title^='Priority']") == 0
      assert count(card_node(html, cards["low"]), "[title^='Priority']") == 1
    end
  end

  describe "neutral and tinted" do
    test "neutral metadata sits in the card-meta row as outlined chips app.css flattens", ctx do
      card =
        card_fixture(ctx.todo, %{
          "title" => "Later",
          "due_date" => days(30),
          "description" => "Words"
        })

      {:ok, _view, html} =
        Slipdock.CardViewHelpers.live_showing(
          ctx.conn,
          ctx.user,
          ctx.board,
          ~p"/boards/#{ctx.board}",
          ~w(due_date description)
        )

      node = card_node(html, card)

      assert "card-meta" in classes(node, "[data-role=card-meta]")
      due = classes(node, "[data-role=card-meta] [title^='Due']")
      assert "chip-line" in due
      refute Enum.any?(due, &String.starts_with?(&1, "bg-"))
      assert "chip-line" in classes(node, "[data-role=card-meta] [title='Has description']")
    end

    test "overdue, due soon, blocked, flagged and waiting keep their tints", ctx do
      overdue = card_fixture(ctx.todo, %{"title" => "Late", "due_date" => days(-3)})
      soon = card_fixture(ctx.todo, %{"title" => "Soon", "due_date" => days(1)})
      flagged = card_fixture(ctx.todo, %{"title" => "Flagged", "flags" => ["blocked"]})
      blocker = card_fixture(ctx.todo, %{"title" => "Blocker"})
      blocked = card_fixture(ctx.todo, %{"title" => "Blocked"})
      {:ok, _} = Boards.Dependencies.add_dependency(blocked, blocker)
      waiting = card_fixture(ctx.doing, %{"title" => "Waiting"})
      {:ok, _} = Boards.Waits.open_wait(waiting, Actor.web(ctx.user), %{"needs" => "A yes"})

      {:ok, _view, html} = live(ctx.conn, ~p"/boards/#{ctx.board}")

      over = classes(card_node(html, overdue), "[data-role=card-meta] [title^='Due']")
      assert "bg-error/15" in over and "text-error" in over
      refute "chip-line" in over

      near = classes(card_node(html, soon), "[data-role=card-meta] [title^='Due']")
      assert "bg-amber-500/15" in near
      refute "chip-line" in near

      flag = classes(card_node(html, flagged), "[data-role=card-meta] [data-flag=blocked]")
      assert "chip-tint" in flag

      lock = classes(card_node(html, blocked), "[data-role=card-meta] [title^='Blocked by']")
      assert "bg-error/15" in lock

      wait = classes(card_node(html, waiting), "[data-role=wait-mark]")
      assert "chip-tint" in wait and "text-warning" in wait
      refute "chip-line" in wait
    end

    test "a list over its WIP limit keeps its red count", ctx do
      {:ok, _} = Boards.Columns.update_column(ctx.todo, %{"wip_limit" => 1})
      for n <- 1..2, do: card_fixture(ctx.todo, %{"title" => "W#{n}"})
      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}")
      assert has_element?(view, ".badge-error[title='WIP limit 1']", "2/1")
    end
  end

  describe "start and due as one range" do
    test "both shown and both set: one range chip instead of two", ctx do
      card =
        card_fixture(ctx.todo, %{
          "title" => "Ranged",
          "start_date" => "2030-01-10",
          "due_date" => "2030-01-20"
        })

      {:ok, _view, html} =
        Slipdock.CardViewHelpers.live_showing(
          ctx.conn,
          ctx.user,
          ctx.board,
          ~p"/boards/#{ctx.board}",
          ~w(start_date due_date)
        )

      node = card_node(html, card)

      range = LazyHTML.query(node, "[data-role=date-range]")
      assert Enum.count(range) == 1
      assert LazyHTML.text(range) =~ "10 Jan 2030 → 20 Jan 2030"
      assert [title] = LazyHTML.attribute(range, "title")
      assert title =~ "Starts Thursday 10 January 2030, due Sunday 20 January 2030"
      assert "chip-line" in classes(node, "[data-role=date-range]")
      # No separate start or due chip beside it.
      assert count(node, "[title^='Due']") == 0
      assert count(node, "[title^='Starts']") == 1

      # Compact cards draw the same range.
      {:ok, _view, html} =
        Slipdock.CardViewHelpers.live_showing(
          ctx.conn,
          ctx.user,
          ctx.board,
          ~p"/boards/#{ctx.board}?density=compact",
          ~w(start_date due_date)
        )

      assert count(card_node(html, card), "[data-role=date-range]") == 1
    end

    test "only one of the two shown, or set: that one's own chip", ctx do
      both = card_fixture(ctx.todo, %{"start_date" => days(5), "due_date" => days(9)})
      start_only = card_fixture(ctx.todo, %{"start_date" => days(5)})
      due_only = card_fixture(ctx.todo, %{"due_date" => days(9)})

      {:ok, _view, html} =
        Slipdock.CardViewHelpers.live_showing(
          ctx.conn,
          ctx.user,
          ctx.board,
          ~p"/boards/#{ctx.board}",
          ~w(start_date due_date)
        )

      assert count(card_node(html, start_only), "[data-role=date-range]") == 0
      assert count(card_node(html, start_only), "[title^='Starts']") == 1
      assert count(card_node(html, due_only), "[data-role=date-range]") == 0
      assert count(card_node(html, due_only), "[title^='Due']") == 1

      {:ok, _view, html} =
        Slipdock.CardViewHelpers.live_showing(
          ctx.conn,
          ctx.user,
          ctx.board,
          ~p"/boards/#{ctx.board}",
          ~w(due_date)
        )

      assert count(card_node(html, both), "[data-role=date-range]") == 0
      assert count(card_node(html, both), "[title^='Due']") == 1

      {:ok, _view, html} =
        Slipdock.CardViewHelpers.live_showing(
          ctx.conn,
          ctx.user,
          ctx.board,
          ~p"/boards/#{ctx.board}",
          ~w(start_date)
        )

      assert count(card_node(html, both), "[data-role=date-range]") == 0
      assert count(card_node(html, both), "[title^='Starts']") == 1
    end

    test "is tinted by its due date: overdue, soon, done, or plain", ctx do
      late = card_fixture(ctx.todo, %{"start_date" => days(-9), "due_date" => days(-2)})
      soon = card_fixture(ctx.todo, %{"start_date" => days(-3), "due_date" => days(1)})

      done =
        card_fixture(ctx.todo, %{
          "start_date" => days(-9),
          "due_date" => days(-2),
          "completed" => true
        })

      {:ok, _view, html} =
        Slipdock.CardViewHelpers.live_showing(
          ctx.conn,
          ctx.user,
          ctx.board,
          ~p"/boards/#{ctx.board}",
          ~w(start_date due_date)
        )

      assert "bg-error/15" in classes(card_node(html, late), "[data-role=date-range]")
      assert "bg-amber-500/15" in classes(card_node(html, soon), "[data-role=date-range]")
      assert "bg-success/15" in classes(card_node(html, done), "[data-role=date-range]")
    end
  end

  describe "the range's words" do
    test "leave the year off this year's dates and keep it on any other" do
      year = Date.utc_today().year

      assert SlipdockComponents.format_range(Date.new!(year, 10, 31), Date.new!(year, 11, 5)) ==
               "31 Oct → 5 Nov"

      assert SlipdockComponents.format_range(Date.new!(year, 12, 30), Date.new!(year + 1, 1, 2)) ==
               "30 Dec → 2 Jan #{year + 1}"

      assert SlipdockComponents.format_range(~D[2001-01-01], ~D[2001-01-01]) ==
               "1 Jan 2001 → 1 Jan 2001"
    end

    test "draw nothing unless both dates are there" do
      start_only = %{
        start_date: ~D[2030-01-10],
        due_date: nil,
        completed: false,
        sub_board: nil,
        rollup: nil
      }

      html =
        render_component(&SlipdockComponents.date_range_badge/1, card: start_only)

      refute html =~ "date-range"
    end
  end
end
