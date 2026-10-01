defmodule Slipdock.SwimlanesTest do
  use Slipdock.DataCase, async: false

  import Slipdock.Fixtures
  alias Slipdock.Boards
  alias Slipdock.Swimlanes
  alias Slipdock.Swimlanes.Config

  @today ~D[2026-09-25]

  describe "Config" do
    test "from_query keeps the base for absent or invalid keys and parses lists" do
      config =
        Config.from_query(%{
          "rows" => "tag",
          "dir" => "sideways",
          "tags" => "1,2,x",
          "priorities" => ["high", "bogus"],
          "due" => "week"
        })

      assert %Config{
               rows: "tag",
               cols: "column",
               dir: "asc",
               tags: [1, 2],
               priorities: ["high"],
               due: "week"
             } = config
    end

    test "from_form treats absent lists as cleared but keeps scalars" do
      current = %Config{rows: "flag", tags: [1], sort: "title"}

      assert %Config{rows: "flag", tags: [], sort: "title", cols: "priority"} =
               Config.from_form(%{"cols" => "priority"}, current)
    end

    test "to_query only emits differences from the base, and round-trips" do
      base = %Config{rows: "tag"}
      config = %Config{rows: "tag", cols: "due_date", tags: [3], due: nil, q: "x"}

      query = Config.to_query(config, base)
      assert query == [cols: "due_date", q: "x", tags: "3"]
      assert Config.from_query(Map.new(query, fn {k, v} -> {to_string(k), v} end), base) == config

      # Clearing a list present in the base is encoded as an empty value.
      assert Config.to_query(%Config{tags: []}, %Config{tags: [1]}) == [tags: ""]
      assert Config.from_query(%{"tags" => ""}, %Config{tags: [1]}).tags == []
    end

    test "to_map / from_map round-trip through JSON-shaped maps" do
      config = %Config{
        rows: "flag",
        cols: "created",
        unit: "month",
        flags: ["blocked"],
        colors: ["none"]
      }

      map = config |> Config.to_map() |> Jason.encode!() |> Jason.decode!()
      assert Config.from_map(map) == config
    end

    test "clear_filters and active_filter_count" do
      config = %Config{q: "a", tags: [1], done: "hide", rows: "flag"}
      assert Config.active_filter_count(config) == 3
      assert Config.clear_filters(config) == %Config{rows: "flag"}
    end
  end

  describe "date buckets" do
    test "keys are the ISO start of the bucket" do
      d = ~D[2026-09-25]
      assert Swimlanes.date_key(d, "day") == "2026-09-25"
      assert Swimlanes.date_key(d, "week") == "2026-09-21"
      assert Swimlanes.date_key(d, "month") == "2026-09-01"
      assert Swimlanes.date_key(d, "quarter") == "2026-07-01"
      assert Swimlanes.date_key(d, "year") == "2026-01-01"
      assert Swimlanes.date_key(nil, "day") == "none"
    end

    test "labels" do
      assert Swimlanes.date_label("2026-09-25", "day", @today) == "Fri 25 Sep"
      assert Swimlanes.date_label("2025-09-25", "day", @today) == "Thu 25 Sep 2025"
      assert Swimlanes.date_label("2026-09-21", "week", @today) == "21–27 Sep"
      assert Swimlanes.date_label("2026-09-28", "week", @today) == "28 Sep – 4 Oct"
      assert Swimlanes.date_label("2026-09-01", "month", @today) == "Sep 2026"
      assert Swimlanes.date_label("2026-07-01", "quarter", @today) == "Q3 2026"
      assert Swimlanes.date_label("2026-01-01", "year", @today) == "2026"
    end
  end

  describe "grid/3" do
    setup do
      board = board_fixture()
      [backlog, todo, doing, _done] = board.columns
      bug = tag_fixture(board, "bug", "red")
      docs = tag_fixture(board, "docs", "teal")

      a =
        card_fixture(backlog, %{
          "title" => "Alpha",
          "priority" => "high",
          "due_date" => "2026-09-25"
        })

      b =
        card_fixture(todo, %{
          "title" => "Bravo",
          "priority" => "high",
          "due_date" => "2026-10-14",
          "flags" => ["blocked"]
        })

      c = card_fixture(doing, %{"title" => "Charlie", "priority" => "low", "completed" => true})
      Boards.toggle_card_tag(a, bug)
      Boards.toggle_card_tag(a, docs)
      Boards.toggle_card_tag(b, bug)

      %{
        board: reload(board),
        a: a,
        b: b,
        c: c,
        bug: bug,
        docs: docs,
        backlog: backlog,
        todo: todo,
        doing: doing
      }
    end

    test "groups by priority x list and hides empty groups by default", ctx do
      grid = Swimlanes.grid(ctx.board, %Config{rows: "priority", cols: "column"}, @today)

      assert Enum.map(grid.rows, & &1.label) == ["High", "Low"]
      assert Enum.map(grid.cols, & &1.label) == ["Backlog", "To Do", "In Progress"]
      assert grid.shown == 3 and grid.hidden == 0

      [high, low] = grid.rows
      assert high.count == 2

      assert Enum.map(high.cells, &Enum.map(&1, fn c -> c.title end)) == [
               ["Alpha"],
               ["Bravo"],
               []
             ]

      assert Enum.map(low.cells, &Enum.map(&1, fn c -> c.title end)) == [[], [], ["Charlie"]]
    end

    test "empty: show keeps every group", ctx do
      grid =
        Swimlanes.grid(
          ctx.board,
          %Config{rows: "priority", cols: "column", empty: "show"},
          @today
        )

      assert Enum.map(grid.rows, & &1.label) == [
               "Critical",
               "High",
               "Medium",
               "Low",
               "No priority"
             ]

      assert length(grid.cols) == 4
    end

    test "a card with several tags appears in each tag row", ctx do
      grid = Swimlanes.grid(ctx.board, %Config{rows: "tag", cols: "none"}, @today)

      assert Enum.map(grid.rows, &{&1.label, &1.count}) == [
               {"bug", 2},
               {"docs", 1},
               {"No tag", 1}
             ]

      assert [%{label: "All cards", count: 4}] = grid.cols
    end

    test "date axes bucket by unit, mark today, and fill gaps when showing empty groups", ctx do
      grid =
        Swimlanes.grid(ctx.board, %Config{rows: "none", cols: "due_date", unit: "week"}, @today)

      assert Enum.map(grid.cols, &{&1.label, &1.count, &1.tone}) == [
               {"21–27 Sep", 1, :current},
               {"12–18 Oct", 1, nil},
               {"No due date", 1, nil}
             ]

      grid =
        Swimlanes.grid(
          ctx.board,
          %Config{rows: "none", cols: "due_date", unit: "week", empty: "show"},
          @today
        )

      assert Enum.map(grid.cols, & &1.label) == [
               "21–27 Sep",
               "28 Sep – 4 Oct",
               "5–11 Oct",
               "12–18 Oct",
               "No due date"
             ]

      grid =
        Swimlanes.grid(ctx.board, %Config{rows: "none", cols: "due_date", unit: "month"}, @today)

      assert Enum.map(grid.cols, & &1.label) == ["Sep 2026", "Oct 2026", "No due date"]

      grid =
        Swimlanes.grid(
          ctx.board,
          %Config{rows: "none", cols: "due_date", unit: "quarter"},
          @today
        )

      assert Enum.map(grid.cols, & &1.label) == ["Q3 2026", "Q4 2026", "No due date"]

      # Past due-date buckets are flagged.
      grid =
        Swimlanes.grid(
          ctx.board,
          %Config{rows: "none", cols: "due_date", unit: "day"},
          ~D[2026-12-01]
        )

      assert Enum.map(grid.cols, & &1.tone) == [:past, :past, nil]
    end

    test "filters", ctx do
      grid = fn overrides ->
        Swimlanes.grid(
          ctx.board,
          struct(Config, Map.merge(%{rows: "none", cols: "none"}, overrides)),
          @today
        )
      end

      titles = fn g ->
        g.rows |> hd() |> Map.get(:cells) |> hd() |> Enum.map(& &1.title) |> Enum.sort()
      end

      assert titles.(grid.(%{tags: [ctx.bug.id]})) == ["Alpha", "Bravo"]
      assert titles.(grid.(%{priorities: ["low"]})) == ["Charlie"]
      assert titles.(grid.(%{flags: ["blocked"]})) == ["Bravo"]
      assert titles.(grid.(%{columns: [ctx.doing.id]})) == ["Charlie"]
      assert titles.(grid.(%{q: "alp"})) == ["Alpha"]
      assert titles.(grid.(%{q: "docs"})) == ["Alpha"]
      assert titles.(grid.(%{due: "today"})) == ["Alpha"]
      assert titles.(grid.(%{due: "week"})) == ["Alpha"]
      assert titles.(grid.(%{due: "month"})) == ["Alpha", "Bravo"]
      assert titles.(grid.(%{due: "none"})) == ["Charlie"]
      assert titles.(grid.(%{due: "has"})) == ["Alpha", "Bravo"]
      assert titles.(grid.(%{done: "hide"})) == ["Alpha", "Bravo"]
      assert titles.(grid.(%{done: "only"})) == ["Charlie"]
      assert grid.(%{done: "only"}).hidden == 2
      assert grid.(%{colors: ["none"]}).shown == 3
    end

    test "sorting", ctx do
      titles = fn config ->
        Swimlanes.grid(
          ctx.board,
          struct(Config, Map.merge(%{rows: "none", cols: "none"}, config)),
          @today
        ).rows
        |> hd()
        |> Map.get(:cells)
        |> hd()
        |> Enum.map(& &1.title)
      end

      assert titles.(%{sort: "position"}) == ["Alpha", "Bravo", "Charlie"]
      assert titles.(%{sort: "title", dir: "desc"}) == ["Charlie", "Bravo", "Alpha"]
      assert titles.(%{sort: "priority", dir: "desc"}) == ["Alpha", "Bravo", "Charlie"]
      assert titles.(%{sort: "priority", dir: "asc"}) == ["Charlie", "Alpha", "Bravo"]
      # Cards without a due date always sort last.
      assert titles.(%{sort: "due_date", dir: "desc"}) == ["Bravo", "Alpha", "Charlie"]
      assert titles.(%{sort: "due_date", dir: "asc"}) == ["Alpha", "Bravo", "Charlie"]
    end
  end

  describe "move_ops/5" do
    test "single-valued axes" do
      config = %Config{unit: "week"}
      card = %Slipdock.Boards.Card{tags: [], flags: [], due_date: ~D[2026-09-25]}

      assert Swimlanes.move_ops("priority", card, "low", "high", config) == [
               {:attrs, %{"priority" => "high"}}
             ]

      assert Swimlanes.move_ops("priority", card, "low", "low", config) == []
      assert Swimlanes.move_ops("column", card, "1", "2", config) == [{:column, 2}]

      assert Swimlanes.move_ops("completed", card, "open", "done", config) == [
               {:attrs, %{"completed" => true}}
             ]

      assert Swimlanes.move_ops("color", card, "red", "none", config) == [
               {:attrs, %{"color" => nil}}
             ]

      assert Swimlanes.move_ops("none", card, "all", "all", config) == []
    end

    test "tags and flags swap the source value for the target one" do
      config = %Config{}
      card = %Slipdock.Boards.Card{tags: [%{id: 1}, %{id: 2}], flags: ["blocked", "starred"]}

      assert Swimlanes.move_ops("tag", card, "1", "3", config) == [{:tags, [2, 3]}]
      assert Swimlanes.move_ops("tag", card, "none", "3", config) == [{:tags, [1, 2, 3]}]
      assert Swimlanes.move_ops("tag", card, "2", "none", config) == [{:tags, [1]}]
      assert Swimlanes.move_ops("tag", nil, nil, "3", config) == [{:tags, [3]}]

      assert Swimlanes.move_ops("flag", card, "blocked", "review", config) == [
               {:attrs, %{"flags" => ["starred", "review"]}}
             ]

      assert Swimlanes.move_ops("flag", card, "starred", "none", config) == [
               {:attrs, %{"flags" => ["blocked"]}}
             ]
    end

    test "due dates move to the start of the target bucket unless already inside it" do
      card = %Slipdock.Boards.Card{tags: [], flags: [], due_date: ~D[2026-09-25]}

      assert Swimlanes.move_ops("due_date", card, "2026-09-21", "2026-10-05", %Config{
               unit: "week"
             }) == [{:attrs, %{"due_date" => ~D[2026-10-05]}}]

      assert Swimlanes.move_ops("due_date", card, "none", "2026-09-21", %Config{unit: "week"}) ==
               []

      assert Swimlanes.move_ops("due_date", card, "2026-09-21", "none", %Config{unit: "week"}) ==
               [{:attrs, %{"due_date" => nil}}]

      assert Swimlanes.move_ops("due_date", nil, nil, "2026-07-01", %Config{unit: "quarter"}) == [
               {:attrs, %{"due_date" => ~D[2026-07-01]}}
             ]
    end

    test "created / updated axes refuse moves" do
      assert [{:error, msg}] =
               Swimlanes.move_ops("created", nil, "2026-09-01", "2026-10-01", %Config{})

      assert msg =~ "created"
    end
  end

  describe "saved views" do
    test "create, find by name, update, delete" do
      board = board_fixture()
      config = %Config{rows: "tag", cols: "due_date", unit: "month"}

      {:ok, view} =
        Boards.create_saved_view(board, %{"name" => "Roadmap", "config" => Config.to_map(config)})

      assert {:ok, ^view} = Boards.find_saved_view(board, "roadmap")
      assert {:ok, ^view} = Boards.find_saved_view(board, view.id)
      assert Config.from_map(view.config) == config

      assert {:error, cs} =
               Boards.create_saved_view(board, %{"name" => "Roadmap", "config" => %{}})

      assert {"already exists on this board", _} = cs.errors[:name]

      {:ok, view} = Boards.update_saved_view(view, %{"name" => "Plan"})
      assert [%{name: "Plan"}] = reload(board).saved_views
      assert Enum.any?(Boards.list_activities(board.id), &(&1.message =~ "saved view"))

      {:ok, _} = Boards.delete_saved_view(view)
      assert reload(board).saved_views == []
    end
  end
end
