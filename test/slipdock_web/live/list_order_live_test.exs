defmodule SlipdockWeb.ListOrderLiveTest do
  @moduledoc """
  List settings: the order a list draws its cards in and the groups it draws
  them under, and the board-wide "at the foot of every list" choices the same
  dialog carries.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Boards, Repo}
  alias Slipdock.Boards.Column

  setup %{conn: conn, user: user} do
    board = board_fixture(%{"name" => "Ordering"}, owner: user)
    column = hd(board.columns)
    %{conn: conn, board: board, column: column}
  end

  defp open_settings(conn, board, column) do
    {:ok, view, _html} = live(conn, ~p"/boards/#{board}")
    view |> with_target("#board-column") |> render_hook("edit_column", %{"id" => column.id})
    view
  end

  # The titles in one list, top to bottom, as drawn: each card's move
  # button names it.
  defp drawn(view, column) do
    html = view |> element("#cards-#{column.id}") |> render()
    for [_, title] <- Regex.scan(~r/aria-label="Move “([^”]+)” to another list"/, html), do: title
  end

  # The group headings in one list, as "Label count".
  defp headings(view, column) do
    html = view |> element("#cards-#{column.id}") |> render()

    for [_, inner] <- Regex.scan(~r|<h3 class="list-group[^"]*">(.*?)</h3>|s, html) do
      inner |> String.replace(~r/<[^>]+>/, " ") |> String.split() |> Enum.join(" ")
    end
  end

  test "the dialog saves sort, direction and grouping onto the list", %{
    conn: conn,
    board: board,
    column: column
  } do
    view = open_settings(conn, board, column)

    view
    |> form("#column-form",
      column: %{sort_by: "due_date", sort_dir: "desc", group_by: "flag"}
    )
    |> render_submit()

    assert %Column{sort_by: "due_date", sort_dir: "desc", group_by: "flag"} =
             Repo.get!(Column, column.id)
  end

  test "board order is the default and puts things back", %{
    conn: conn,
    board: board,
    column: column
  } do
    {:ok, _} = Boards.update_column(column, %{"sort_by" => "priority", "group_by" => "tag"})
    view = open_settings(conn, board, column)

    view |> form("#column-form", column: %{sort_by: "", group_by: ""}) |> render_submit()

    assert %Column{sort_by: nil, group_by: nil} = Repo.get!(Column, column.id)
  end

  test "a sorted list draws its cards in that order and says so; drag only moves between lists",
       %{conn: conn, board: board, column: column} do
    card_fixture(column, %{"title" => "Low", "priority" => "low"})
    card_fixture(column, %{"title" => "Critical", "priority" => "critical"})
    card_fixture(column, %{"title" => "Medium", "priority" => "medium"})

    {:ok, view, _} = live(conn, ~p"/boards/#{board}")
    assert has_element?(view, ~s|#cards-#{column.id}[data-sort="true"]|)
    assert drawn(view, column) == ~w(Low Critical Medium)

    {:ok, _} = Boards.update_column(column, %{"sort_by" => "priority", "sort_dir" => "desc"})
    {:ok, view, _} = live(conn, ~p"/boards/#{board}")

    assert drawn(view, column) == ~w(Critical Medium Low)
    assert has_element?(view, ~s|#cards-#{column.id}[data-sort="false"]|)

    assert has_element?(
             view,
             ~s|#column-#{column.id} [title^="Cards drawn by priority, descending"]|
           )

    assert headings(view, column) == []

    # The stored order is untouched: back to board order, back as they were.
    {:ok, _} = Boards.update_column(Repo.get!(Column, column.id), %{"sort_by" => ""})
    {:ok, view, _} = live(conn, ~p"/boards/#{board}")
    assert drawn(view, column) == ~w(Low Critical Medium)
  end

  test "a grouped list draws a heading over each group, with its count", %{
    conn: conn,
    board: board,
    column: column
  } do
    card_fixture(column, %{"title" => "Free"})
    card_fixture(column, %{"title" => "Stuck", "flags" => ["blocked"]})
    card_fixture(column, %{"title" => "Also stuck", "flags" => ["blocked", "waiting"]})

    {:ok, _} = Boards.update_column(column, %{"group_by" => "flag"})
    {:ok, view, _} = live(conn, ~p"/boards/#{board}")

    assert headings(view, column) == ["Blocked 2", "No flag 1"]
    assert drawn(view, column) == ["Stuck", "Also stuck", "Free"]
    # Grouped without a sort, the cards inside a group can still be arranged.
    assert has_element?(view, ~s|#cards-#{column.id}[data-sort="true"]|)
  end

  test "filters still apply inside groups", %{conn: conn, board: board, column: column} do
    card_fixture(column, %{"title" => "Needle", "flags" => ["blocked"]})
    card_fixture(column, %{"title" => "Haystack"})
    {:ok, _} = Boards.update_column(column, %{"group_by" => "flag"})

    {:ok, view, _} = live(conn, ~p"/boards/#{board}")
    render_hook(view, "search", %{"q" => "needle"})

    assert headings(view, column) == ["Blocked 1"]
    assert render(view) =~ "1 hidden by filters"
  end

  describe "at the foot of every list" do
    test "the owner's choices are saved to the board", %{
      conn: conn,
      board: board,
      column: column
    } do
      view = open_settings(conn, board, column)
      assert has_element?(view, "#column-add-page[checked]")

      view
      |> form("#column-form", column: %{add_page: "false", add_document: "false"})
      |> render_submit()

      assert %{add_card: true, add_page: false, add_document: false} = Boards.get_board!(board.id)
    end

    test "somebody who can only write to the board neither sees nor changes them", %{conn: conn} do
      owner = user_fixture("owner-#{System.unique_integer([:positive])}@example.com")
      board = board_fixture(%{"name" => "Theirs"}, owner: owner)
      share_fixture(board, user_fixture(), "write")
      column = hd(board.columns)

      view = open_settings(conn, board, column)
      refute has_element?(view, "#column-add-page")

      view
      |> with_target("#board-column")
      |> render_hook("save_column", %{"column" => %{"name" => "Renamed", "add_page" => "false"}})

      assert Repo.get!(Column, column.id).name == "Renamed"
      assert Boards.get_board!(board.id).add_page
    end
  end
end
