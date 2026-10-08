defmodule SlipdockWeb.DisplayLiveTest do
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures
  alias Slipdock.Boards
  alias Slipdock.Swimlanes.Config

  setup do
    board = board_fixture(%{"name" => "Facets"})
    [backlog | _] = board.columns

    card =
      card_fixture(backlog, %{
        "title" => "Rich card",
        "priority" => "high",
        "start_date" => "2030-01-10",
        "due_date" => "2030-01-20"
      })

    %{board: reload(board), card: card}
  end

  test "each density keeps its own set of facets" do
    assert Config.shown(%Config{}) == MapSet.new(Config.facet_keys())
    compact = Config.shown(%Config{density: "compact"})
    assert MapSet.member?(compact, "priority")
    refute MapSet.member?(compact, "comments")

    config = Config.from_query(%{"show" => "priority,bogus,tags", "density" => "compact"})
    assert config.show == ["tags", "priority"]
    # The compact set is untouched by the comfortable chooser…
    assert config.show_compact == %Config{}.show_compact
    # …and a chooser that is not on the form keeps its value.
    assert Config.from_form(%{"density" => "normal"}, config).show == ["tags", "priority"]
    # The hidden empty entry lets a form clear a set completely.
    assert Config.from_form(%{"show" => [""]}, config).show == []

    assert Config.table_fields(%Config{fields: ["id"], fields_compact: ["tags"]}) == ["id"]

    assert Config.table_fields(%Config{
             density: "compact",
             fields: ["id"],
             fields_compact: ["tags"]
           }) == ["tags"]

    assert Enum.map(Config.facets(:timeline), &elem(&1, 0)) == ~w(cover priority flags subcards)
  end

  test "board view honours the chosen facets, and saves them in a view", %{
    conn: conn,
    board: board,
    card: card
  } do
    {:ok, view, _} = live(conn, ~p"/boards/#{board}")
    assert has_element?(view, "#card-#{card.id} [title^='Priority']")
    assert has_element?(view, "#card-#{card.id} [title^='Due']")
    assert has_element?(view, "#card-#{card.id} [title^='Starts']")

    view |> form("#swim-config", %{"show" => ["priority"]}) |> render_change()
    assert_patch(view, ~p"/boards/#{board}?show=priority")
    assert has_element?(view, "#card-#{card.id} [title^='Priority']")
    refute has_element?(view, "#card-#{card.id} [title^='Due']")
    refute has_element?(view, "#card-#{card.id} [title^='Starts']")

    # Switching to compact cards uses the compact set, which is unchanged.
    view |> form("#swim-config", %{"density" => "compact"}) |> render_change()
    assert_patch(view, ~p"/boards/#{board}?density=compact&show=priority")
    assert has_element?(view, "#card-#{card.id} [title^='Due']")
    view |> form("#swim-config", %{"show_compact" => ["due_date"]}) |> render_change()

    assert_patch(
      view,
      ~p"/boards/#{board}?density=compact&show=priority&show_compact=due_date"
    )

    refute has_element?(view, "#card-#{card.id} [title^='Priority']")
    assert has_element?(view, "#card-#{card.id} [title^='Due']")

    # Opening a card keeps the display settings in the URL.
    view |> element("#card-#{card.id}") |> render_click()

    assert_patch(
      view,
      ~p"/boards/#{board}/cards/#{card.id}?density=compact&show=priority&show_compact=due_date"
    )

    # Both sets travel with a saved view of the board.
    view |> form("form[phx-submit=swim_save_view]", %{"name" => "Slim"}) |> render_submit()
    [saved] = Boards.list_saved_views(board.id)
    assert saved.config["mode"] == "board" and saved.config["density"] == "compact"
    assert saved.config["show"] == ["priority"]
    assert saved.config["show_compact"] == ["due_date"]
    assert_patch(view, ~p"/boards/#{board}?view=#{saved.id}")
    refute has_element?(view, "#card-#{card.id} [title^='Priority']")
  end

  test "a table keeps separate columns per density", %{conn: conn, board: board, card: card} do
    {:ok, view, _} = live(conn, ~p"/boards/#{board}/table")
    view |> form("#swim-config", %{"fields" => ["title", "id"]}) |> render_change()
    assert_patch(view, ~p"/boards/#{board}/table?fields=title%2Cid")
    assert has_element?(view, "#card-table th", "ID")
    refute has_element?(view, "#card-table th", "Priority")

    view |> form("#swim-config", %{"density" => "compact"}) |> render_change()
    assert_patch(view, ~p"/boards/#{board}/table?density=compact&fields=title%2Cid")
    assert has_element?(view, "#card-table th", "Priority")
    refute has_element?(view, "#card-table th", "ID")

    view |> form("#swim-config", %{"fields_compact" => ["title", "tags"]}) |> render_change()

    assert_patch(
      view,
      ~p"/boards/#{board}/table?density=compact&fields=title%2Cid&fields_compact=title%2Ctags"
    )

    assert has_element?(view, "#card-table th", "Tags")
    refute has_element?(view, "#card-table th", "Priority")
    assert has_element?(view, "#card-table td", "Rich card")
    _ = card
  end

  describe "list width" do
    test "is one of four widths, normal by default, and kept only when changed" do
      assert %Config{}.width == "normal"
      assert Enum.map(Config.widths(), &elem(&1, 0)) == ~w(narrow normal wide wider)
      assert Config.from_query(%{"width" => "wide"}).width == "wide"
      # Anything else falls back rather than reaching a class name.
      assert Config.from_query(%{"width" => "w-screen"}).width == "normal"
      assert Config.from_query(%{"width" => ""}).width == "normal"
      # A setting the menu does not send leaves the width alone.
      assert Config.from_form(%{"density" => "compact"}, %Config{width: "narrow"}).width ==
               "narrow"

      assert Config.to_query(%Config{}) == []
      assert Config.to_query(%Config{width: "wider"}) == [width: "wider"]
      assert Config.to_map(%Config{width: "wider"})["width"] == "wider"
      assert Config.from_map(%{"width" => "narrow"}).width == "narrow"
      # A view saved before there was a width opens at the normal width.
      assert Config.from_map(%{"density" => "compact"}).width == "normal"
    end

    test "the board's lists take the chosen width, and a saved view keeps it", %{
      conn: conn,
      board: board
    } do
      [first | _] = board.columns
      {:ok, view, _} = live(conn, ~p"/boards/#{board}")
      assert has_element?(view, "#display-width input[name=width][value=normal][checked]")
      assert has_element?(view, "#column-#{first.id}.w-72")

      view |> form("#swim-config", %{"width" => "wide"}) |> render_change()
      assert_patch(view, ~p"/boards/#{board}?width=wide")
      assert has_element?(view, "#column-#{first.id}.w-96")
      refute has_element?(view, "#column-#{first.id}.w-72")
      assert has_element?(view, "#display-width input[name=width][value=wide][checked]")

      view |> form("#swim-config", %{"width" => "narrow"}) |> render_change()
      assert_patch(view, ~p"/boards/#{board}?width=narrow")
      assert has_element?(view, "#column-#{first.id}.w-60")

      view
      |> form("form[phx-submit=swim_save_view]", %{"name" => "Slim lists"})
      |> render_submit()

      [saved] = Boards.list_saved_views(board.id)
      assert saved.config["mode"] == "board" and saved.config["width"] == "narrow"

      # Opening the view later brings the width back.
      {:ok, view, _} = live(conn, ~p"/boards/#{board}?view=#{saved.id}")
      assert has_element?(view, "#column-#{first.id}.w-60")

      {:ok, view, _} = live(conn, ~p"/boards/#{board}?width=wider")
      assert has_element?(view, "#column-#{first.id}.w-\\[30rem\\]")
    end

    test "a width the menu does not offer draws normal lists", %{conn: conn, board: board} do
      [first | _] = board.columns
      {:ok, view, _} = live(conn, ~p"/boards/#{board}?width=huge")
      assert has_element?(view, "#column-#{first.id}.w-72")
    end

    test "swimlane columns take it as their narrowest width", %{conn: conn, board: board} do
      {:ok, view, _} = live(conn, ~p"/boards/#{board}/swimlanes")
      assert has_element?(view, "#display-width")
      assert has_element?(view, "#swim-grid[style*='minmax(17rem, 1fr)']")

      view |> form("#swim-config", %{"density" => "compact"}) |> render_change()
      assert has_element?(view, "#swim-grid[style*='minmax(15rem, 1fr)']")

      view |> form("#swim-config", %{"width" => "narrow"}) |> render_change()
      assert has_element?(view, "#swim-grid[style*='minmax(12rem, 1fr)']")

      view |> form("#swim-config", %{"width" => "wider"}) |> render_change()
      assert has_element?(view, "#swim-grid[style*='minmax(28rem, 1fr)']")
    end

    test "views without lists do not offer it", %{conn: conn, board: board} do
      for path <- [~p"/boards/#{board}/table", ~p"/boards/#{board}/calendar"] do
        {:ok, view, _} = live(conn, path)
        refute has_element?(view, "#display-width")
      end
    end
  end
end
