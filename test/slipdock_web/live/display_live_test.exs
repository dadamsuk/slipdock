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
end
