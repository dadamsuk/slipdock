defmodule SlipdockWeb.BoardSearchResultsTest do
  @moduledoc """
  A searched or filtered board is one list down the page, grouped by list
  (#2809): the groups in board order with their counts, the lists with no
  matches on one line, Done folded, the Board button back to the columns,
  and Clear back to the columns too.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias SlipdockWeb.BoardLive.SearchResults

  # The default lists: Backlog, To Do, In Progress, Done.
  setup %{conn: conn, user: user} do
    board = board_fixture(%{"name" => "Searching"}, owner: user)
    [backlog, todo, doing, done] = board.columns

    card_fixture(todo, %{"title" => "Deploy script skips migrations"})
    card_fixture(todo, %{"title" => "Rate-limit the deploy webhook"})
    card_fixture(todo, %{"title" => "Unrelated chore"})
    card_fixture(doing, %{"title" => "Deploy notice on the Now page"})
    card_fixture(done, %{"title" => "Deploy by pull request"})
    card_fixture(backlog, %{"title" => "Something else"})

    %{conn: conn, board: board, lists: %{backlog: backlog, todo: todo, doing: doing, done: done}}
  end

  # The groups as drawn: each heading's list name and count, top to bottom.
  defp groups(view) do
    html = view |> element("#search-results") |> render()

    for [_, inner] <-
          Regex.scan(~r|<button[^>]*id="result-heading-\d+"[^>]*>(.*?)</button>|s, html) do
      inner |> String.replace(~r/<[^>]+>/, " ") |> String.split() |> Enum.join(" ")
    end
  end

  test "a search draws the matches grouped by list, in board order, with counts", %{
    conn: conn,
    board: board,
    lists: lists
  } do
    {:ok, view, _html} = live(conn, ~p"/boards/#{board}")
    refute has_element?(view, "#search-results")
    assert has_element?(view, "#board-scroll")

    render_hook(view, "search", %{"q" => "deploy"})

    assert has_element?(view, "#search-results")
    refute has_element?(view, "#board-scroll")
    refute has_element?(view, "#column-#{lists.todo.id}")
    assert view |> element("#search-summary") |> render() =~ "4 cards match in 3 lists"
    # Done has a match, so it starts folded and says it can be shown.
    assert groups(view) == ["To Do 2", "In Progress 1", "Done 1 show ›"]

    rows = view |> element("#result-rows-#{lists.todo.id}") |> render()
    assert rows =~ "Deploy script skips migrations"
    assert rows =~ "Rate-limit the deploy webhook"
    refute rows =~ "Unrelated chore"
    # Each row keeps the move menu, so a card moves without dragging.
    assert rows =~ "Move “Deploy script skips migrations” to another list"
  end

  test "the lists with no matches are named on one line at the end", %{
    conn: conn,
    board: board,
    lists: lists
  } do
    {:ok, view, _html} = live(conn, ~p"/boards/#{board}")
    render_hook(view, "search", %{"q" => "deploy"})

    assert view |> element("#search-no-matches") |> render() =~ "Backlog: no matches"
    refute has_element?(view, "#result-group-#{lists.backlog.id}")

    # Everything matches: no such line.
    render_hook(view, "search", %{"q" => "e"})
    refute has_element?(view, "#search-no-matches")
  end

  test "clicking a heading folds and unfolds its group; Done starts folded", %{
    conn: conn,
    board: board,
    lists: lists
  } do
    {:ok, view, _html} = live(conn, ~p"/boards/#{board}")
    render_hook(view, "search", %{"q" => "deploy"})

    refute has_element?(view, "#result-rows-#{lists.done.id}")
    assert has_element?(view, "#result-group-#{lists.done.id}[data-folded=true]")

    view |> element("#result-heading-#{lists.done.id}") |> render_click()

    assert view |> element("#result-rows-#{lists.done.id}") |> render() =~
             "Deploy by pull request"

    view |> element("#result-heading-#{lists.todo.id}") |> render_click()
    refute has_element?(view, "#result-rows-#{lists.todo.id}")
    view |> element("#result-heading-#{lists.todo.id}") |> render_click()
    assert has_element?(view, "#result-rows-#{lists.todo.id}")
  end

  test "a row opens the card panel", %{conn: conn, board: board, lists: lists} do
    card = card_fixture(lists.todo, %{"title" => "Deploy the panel opener"})
    {:ok, view, _html} = live(conn, ~p"/boards/#{board}")
    render_hook(view, "search", %{"q" => "panel opener"})

    view |> element("#search-results #card-#{card.id}") |> render_click()
    assert_patch(view, ~p"/boards/#{board}/cards/#{card.id}")
  end

  test "Board puts the columns back for this search, and List the grouped list", %{
    conn: conn,
    board: board,
    lists: lists
  } do
    {:ok, view, _html} = live(conn, ~p"/boards/#{board}")
    render_hook(view, "search", %{"q" => "deploy"})

    view |> element("#search-layout-toggle") |> render_click()
    refute has_element?(view, "#search-results")
    assert has_element?(view, "#column-#{lists.todo.id}")
    assert render(view) =~ "1 hidden by filters"
    # Still filtered: the banner and its count stay.
    assert view |> element("#search-summary") |> render() =~ "4 cards match in 3 lists"

    # A new search keeps the columns while the filter stays on.
    render_hook(view, "search", %{"q" => "deploy script"})
    assert has_element?(view, "#column-#{lists.todo.id}")

    view |> element("#search-layout-toggle") |> render_click()
    assert has_element?(view, "#search-results")
  end

  test "clearing the search brings the columns back, and the next search is a list again", %{
    conn: conn,
    board: board,
    lists: lists
  } do
    {:ok, view, _html} = live(conn, ~p"/boards/#{board}")
    render_hook(view, "search", %{"q" => "deploy"})
    view |> element("#result-heading-#{lists.todo.id}") |> render_click()

    view |> element("#search-results-banner button[phx-click=clear_filters]") |> render_click()
    refute has_element?(view, "#search-results")
    assert has_element?(view, "#column-#{lists.todo.id}")
    assert render(view) =~ "Unrelated chore"

    # The Board choice and the folds went with the search.
    render_hook(view, "search", %{"q" => "deploy"})
    view |> element("#search-layout-toggle") |> render_click()
    render_hook(view, "search", %{"q" => ""})
    assert has_element?(view, "#column-#{lists.todo.id}")
    render_hook(view, "search", %{"q" => "deploy"})
    assert has_element?(view, "#search-results")
    assert has_element?(view, "#result-rows-#{lists.todo.id}")
  end

  test "a filter, not only a search, draws the grouped list", %{
    conn: conn,
    board: board,
    lists: lists
  } do
    {:ok, view, _html} = live(conn, ~p"/boards/#{board}")
    render_hook(view, "filter_priority", %{"priority" => "high"})

    assert has_element?(view, "#search-results")
    assert view |> element("#search-summary") |> render() =~ "0 cards match in 0 lists"

    assert view |> element("#search-no-matches") |> render() =~
             "Backlog, To Do, In Progress, Done: no matches"

    refute has_element?(view, "#result-group-#{lists.todo.id}")
  end

  test "a narrow screen gets the grouped list instead of the pager", %{conn: conn, board: board} do
    {:ok, view, _html} = live(conn, ~p"/boards/#{board}")
    render_hook(view, "viewport", %{"width" => 390})
    assert has_element?(view, "#list-pager")

    render_hook(view, "search", %{"q" => "deploy"})
    assert has_element?(view, "#search-results")
    refute has_element?(view, "#list-pager")
  end

  test "in select mode a group's select-all picks its matches", %{
    conn: conn,
    board: board,
    lists: lists
  } do
    {:ok, view, _html} = live(conn, ~p"/boards/#{board}")
    render_hook(view, "search", %{"q" => "deploy"})
    refute has_element?(view, "#select-list-#{lists.todo.id}")

    render_click(view, "toggle_select_mode", %{})
    view |> element("#select-list-#{lists.todo.id}") |> render_click()
    assert has_element?(view, "#bulk-count", "2 selected")
    assert has_element?(view, "#select-list-#{lists.todo.id}[aria-pressed=true]")
  end

  test "bad event params change nothing", %{conn: conn, board: board} do
    {:ok, view, _html} = live(conn, ~p"/boards/#{board}")
    render_hook(view, "search", %{"q" => "deploy"})

    render_hook(view, "toggle_result_group", %{"id" => "nope"})
    render_hook(view, "search_layout", %{"layout" => "sideways"})
    render_hook(view, "search_layout", %{})
    assert has_element?(view, "#search-results")
  end

  describe "folding" do
    test "a done list with matches, or any group over 10, starts folded", %{lists: lists} do
      assert SearchResults.folded_by_default?(lists.done, 1)
      refute SearchResults.folded_by_default?(lists.done, 0)
      refute SearchResults.folded_by_default?(lists.todo, 10)
      assert SearchResults.folded_by_default?(lists.todo, 11)
    end

    test "a click flips the default", %{lists: lists} do
      folds = MapSet.new([lists.done.id, lists.todo.id])
      refute SearchResults.folded?(lists.done, 3, folds)
      assert SearchResults.folded?(lists.todo, 3, folds)
      refute SearchResults.folded?(lists.doing, 3, folds)
    end
  end

  test "the summary counts matches and the lists that have them" do
    one = %{items: [{:card, %{}}]}
    none = %{items: []}
    assert SearchResults.summary([one, none]) == "1 card matches in 1 list"
    assert SearchResults.summary([one, one, none]) == "2 cards match in 2 lists"
  end
end
