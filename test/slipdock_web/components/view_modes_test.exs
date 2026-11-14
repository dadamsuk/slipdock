defmodule SlipdockWeb.ViewModesTest do
  # A view mode's icon and path come from the view switcher's own list
  # (`SlipdockComponents.view_tabs_list/0`), so a saved view in any mode
  # `Config` allows gets its own (#2877: Prioritise used to get swimlanes').
  use ExUnit.Case, async: true
  use SlipdockWeb, :verified_routes

  import SlipdockWeb.SwimlaneComponents,
    only: [mode_icon: 1, view_mode_path: 2, view_mode_path: 3]

  alias Slipdock.Swimlanes.Config
  alias SlipdockWeb.SlipdockComponents

  @swimlanes_icon "hero-squares-2x2"

  describe "mode_icon/1" do
    test "every mode a saved view can hold has an icon of its own" do
      icons = Map.new(Config.modes(), &{&1, mode_icon(&1)})

      for {mode, icon} <- icons do
        assert String.starts_with?(icon, "hero-"), "#{mode} has no icon"
        assert mode == "swimlanes" or icon != @swimlanes_icon, "#{mode} falls back to swimlanes"
      end

      assert icons |> Map.values() |> Enum.uniq() |> length() == map_size(icons)
    end

    test "is the icon the view switcher shows for that view" do
      tabs = Map.new(SlipdockComponents.view_tabs_list(), fn t -> {elem(t, 0), elem(t, 3)} end)

      for mode <- Config.modes() do
        assert mode_icon(mode) == Map.fetch!(tabs, String.to_existing_atom(mode))
      end
    end

    test "a Prioritise view has the scale, not the swimlanes grid" do
      assert mode_icon("prioritise") == "hero-scale"
      assert mode_icon(:prioritise) == "hero-scale"
    end

    test "takes an atom or the stored string" do
      assert mode_icon(:table) == "hero-table-cells"
      assert mode_icon("table") == "hero-table-cells"
      assert mode_icon(:swimlanes) == @swimlanes_icon
    end

    test "an unknown or missing mode is swimlanes" do
      assert mode_icon("nope") == @swimlanes_icon
      assert mode_icon(nil) == @swimlanes_icon
      assert mode_icon("") == @swimlanes_icon
      # A page of its own in the switcher, but not a mode a saved view holds.
      assert mode_icon("visualise") == @swimlanes_icon
    end

    test "a stored mode that isn't a string is swimlanes, not a crash" do
      assert mode_icon(%{"a" => 1}) == @swimlanes_icon
      assert mode_icon([%{}]) == @swimlanes_icon
      assert mode_icon(["table"]) == @swimlanes_icon
      assert mode_icon(3) == @swimlanes_icon
      assert mode_icon(1.5) == @swimlanes_icon
    end
  end

  describe "view_mode_path/3" do
    test "every mode has the URL it always had" do
      expected = %{
        "board" => "/boards/7",
        "swimlanes" => "/boards/7/swimlanes",
        "table" => "/boards/7/table",
        "timeline" => "/boards/7/timeline",
        "calendar" => "/boards/7/calendar",
        "outline" => "/boards/7/outline",
        "narrative" => "/boards/7/narrative",
        "prioritise" => "/boards/7/prioritise"
      }

      assert Enum.sort(Map.keys(expected)) == Enum.sort(Config.modes())

      for {mode, path} <- expected do
        assert view_mode_path(7, mode) == path
        assert view_mode_path(7, String.to_existing_atom(mode)) == path
        assert view_mode_path(7, mode, view: 3) == path <> "?view=3"
      end
    end

    test "every mode has a path of its own" do
      paths = Enum.map(Config.modes(), &view_mode_path(7, &1))
      assert Enum.uniq(paths) == paths
    end

    test "takes a board as well as its id" do
      assert view_mode_path(%Slipdock.Boards.Board{id: 12}, "table") == "/boards/12/table"
    end

    test "a query is encoded, as a list or a map" do
      assert view_mode_path(7, :table, q: "a b", sort: "due") == "/boards/7/table?q=a+b&sort=due"
      assert view_mode_path(7, :board, %{"view" => 4}) == "/boards/7?view=4"
      assert view_mode_path(7, :board, tags: ["x", "y"]) == "/boards/7?tags[]=x&tags[]=y"
    end

    test "the query is encoded as a verified route's is, whatever order it came in" do
      query = [unit: "month", rows: "column", date: "2030-01-15"]

      assert view_mode_path(7, :timeline, query) == ~p"/boards/7/timeline?#{query}"
      assert view_mode_path(7, :board, query) == ~p"/boards/7?#{query}"
      assert view_mode_path(7, "nope", query) == ~p"/boards/7/swimlanes?#{query}"

      assert view_mode_path(7, :timeline, query) ==
               "/boards/7/timeline?date=2030-01-15&rows=column&unit=month"
    end

    test "an empty query adds nothing" do
      assert view_mode_path(7, :calendar, []) == "/boards/7/calendar"
      assert view_mode_path(7, :calendar, %{}) == "/boards/7/calendar"
    end

    test "an unknown or missing mode is swimlanes" do
      assert view_mode_path(7, "nope") == "/boards/7/swimlanes"
      assert view_mode_path(7, nil, view: 1) == "/boards/7/swimlanes?view=1"
      assert view_mode_path(7, "visualise") == "/boards/7/swimlanes"
    end

    test "a stored mode that isn't a string is swimlanes, not a crash" do
      assert view_mode_path(7, %{"a" => 1}) == "/boards/7/swimlanes"
      assert view_mode_path(7, [%{}], view: 2) == "/boards/7/swimlanes?view=2"
      assert view_mode_path(7, ["table"]) == "/boards/7/swimlanes"
      assert view_mode_path(7, 3) == "/boards/7/swimlanes"
    end
  end
end
