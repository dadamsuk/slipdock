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
    # Without card views put on: the config's own set, and the marks (#2031).
    assert Config.shown(%Config{}) == MapSet.new(Config.default_show() ++ Config.marks_on())
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

  test "the board follows the reader's card views, not the URL's show (#2031)", %{
    conn: conn,
    board: board,
    card: card,
    user: user
  } do
    {:ok, view, _} = live(conn, ~p"/boards/#{board}")
    assert has_element?(view, "#card-#{card.id} [title^='Priority']")
    assert has_element?(view, "#card-#{card.id} [title^='Due']")
    # The start date is off by default (#1708).
    refute has_element?(view, "#card-#{card.id} [title^='Starts']")
    # The menu no longer chooses facets: it links to the editor.
    refute has_element?(view, "#display-show-comfortable")
    assert has_element?(view, ~s(#edit-card-views[href="/card-views?board=#{board.id}"]))

    Slipdock.CardViewHelpers.show_on_cards(user, board, ~w(priority start_date))
    assert has_element?(view, "#card-#{card.id} [title^='Priority']")
    refute has_element?(view, "#card-#{card.id} [title^='Due']")

    # An old link's show= no longer decides: the card view does.
    {:ok, view, _} = live(conn, ~p"/boards/#{board}?show=due_date")
    refute has_element?(view, "#card-#{card.id} [title^='Due']")
    assert has_element?(view, "#card-#{card.id} [title^='Priority']")

    # Compact cards follow the same card view.
    {:ok, view, _} = live(conn, ~p"/boards/#{board}?density=compact")
    assert has_element?(view, "#card-#{card.id} [title^='Priority']")
    refute has_element?(view, "#card-#{card.id} [title^='Due']")
  end

  test "a saved view names a card view, which sits above the list while it is open", %{
    conn: conn,
    board: board,
    card: card,
    user: user
  } do
    {:ok, _} = Slipdock.CardViews.create(user, %{"name" => "Dates", "show" => "due_date"})
    Slipdock.CardViewHelpers.show_on_cards(user, board, ["priority"], list: hd(board.columns))

    {:ok, view, _} = live(conn, ~p"/boards/#{board}")
    refute has_element?(view, "#card-#{card.id} [title^='Due']")
    assert has_element?(view, "#display-view-card-view option[value='Dates']")

    view |> form("#swim-config", %{"card_view" => "Dates"}) |> render_change()
    assert_patch(view, ~p"/boards/#{board}?card_view=Dates")
    assert has_element?(view, "#card-#{card.id} [title^='Due']")

    view |> form("form[phx-submit=swim_save_view]", %{"name" => "With dates"}) |> render_submit()
    [saved] = Boards.list_saved_views(board.id)
    assert saved.config["card_view"] == "Dates"
    # The card front itself is never stored in the view any more.
    {:ok, view, _} = live(conn, ~p"/boards/#{board}?view=#{saved.id}")
    assert has_element?(view, "#card-#{card.id} [title^='Due']")

    # Without the saved view, the list's own level decides again.
    {:ok, view, _} = live(conn, ~p"/boards/#{board}")
    refute has_element?(view, "#card-#{card.id} [title^='Due']")

    # Somebody without a card view of that name sees their own levels.
    other =
      Slipdock.Fixtures.user_fixture("other-#{System.unique_integer([:positive])}@example.com")

    {:ok, _} = Slipdock.Access.grant(board, other, "read", user)
    conn2 = log_in_user(build_conn(), other)
    {:ok, view, _} = live(conn2, ~p"/boards/#{board}?view=#{saved.id}")
    assert has_element?(view, "#card-#{card.id} [title^='Due']")
    {:ok, _} = Slipdock.CardViews.update_level(other, {:board, board}, %{"hide" => "due_date"})
    {:ok, view, _} = live(conn2, ~p"/boards/#{board}?view=#{saved.id}")
    refute has_element?(view, "#card-#{card.id} [title^='Due']")
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
