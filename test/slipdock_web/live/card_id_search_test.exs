defmodule SlipdockWeb.CardIdSearchTest do
  @moduledoc """
  A card's id (`123`, `#123`) or link in a board's search box finds that card
  (#2097): the board's filter matches it (`Slipdock.Filters`,
  `Slipdock.Swimlanes`), `Slipdock.Boards.Cards.list_cards/2`'s `"q"` does for the
  API, the CLI and MCP, and a card elsewhere in the board's tree is offered in
  the strip under the toolbar.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Access, Boards, Filters, Swimlanes}
  alias Slipdock.Swimlanes.Config

  setup %{user: user} do
    board = board_fixture(%{"name" => "Product"}, owner: user, derive_keys: true)
    board = Boards.get_board!(board.id)
    [backlog | _] = board.columns
    wanted = card_fixture(backlog, %{"title" => "Fix the login page"})
    other = card_fixture(backlog, %{"title" => "Write the release notes"})
    %{board: board, backlog: backlog, wanted: wanted, other: other}
  end

  describe "Filters.matches?/2" do
    test "a card matches its id, with or without #, and its link", %{wanted: wanted, other: other} do
      filters = &Map.put(Filters.empty(), :q, &1)

      for q <- [
            "#{wanted.id}",
            "##{wanted.id}",
            " # #{wanted.id} ",
            "/boards/1/cards/#{wanted.id}"
          ] do
        assert Filters.matches?(wanted, filters.(q)), "expected #{inspect(q)} to match"
        refute Filters.matches?(other, filters.(q)), "expected #{inspect(q)} not to match"
      end
    end

    test "a page is not named by its id", %{user: user, board: board} do
      page = page_fixture(board, %{"title" => "Runbook"}, user: user)
      refute Filters.matches?(page, Map.put(Filters.empty(), :q, "##{page.id}"))
    end

    test "words still match as before", %{wanted: wanted} do
      assert Filters.matches?(wanted, Map.put(Filters.empty(), :q, "login"))
      refute Filters.matches?(wanted, Map.put(Filters.empty(), :q, "#login"))
    end
  end

  describe "Swimlanes.matches?/2" do
    test "the views' filter matches a card's id too", %{wanted: wanted, other: other} do
      wanted = Slipdock.Repo.preload(wanted, :tags)
      other = Slipdock.Repo.preload(other, :tags)
      config = %Config{q: "##{wanted.id}"}

      assert Swimlanes.matches?(wanted, config)
      refute Swimlanes.matches?(other, config)
    end
  end

  describe "Boards.Cards.list_cards/2 \"q\"" do
    test "an id or #id finds the card; words still find by title", %{
      board: board,
      wanted: wanted
    } do
      titles = &(board |> Boards.Cards.list_cards(%{"q" => &1}) |> Enum.map(fn c -> c.title end))

      assert titles.("#{wanted.id}") == ["Fix the login page"]
      assert titles.("##{wanted.id}") == ["Fix the login page"]
      assert titles.("release") == ["Write the release notes"]
      assert titles.("#999999999") == []
    end

    test "a number in a title is still found by text", %{board: board, backlog: backlog} do
      card_fixture(backlog, %{"title" => "Upgrade to 9876"})

      assert board |> Boards.Cards.list_cards(%{"q" => "9876"}) |> Enum.map(& &1.title) == [
               "Upgrade to 9876"
             ]
    end
  end

  describe "a board's search box" do
    test "a card's id shows that card and hides the rest", %{
      conn: conn,
      board: board,
      wanted: wanted
    } do
      {:ok, view, _} = live(conn, ~p"/boards/#{board}")
      assert render(view) =~ "Write the release notes"

      html = view |> form("#board-search", %{"q" => "##{wanted.id}"}) |> render_change()

      assert html =~ "Fix the login page"
      refute html =~ "Write the release notes"
      # On this board: the filter shows it, so the strip offers nothing more.
      refute has_element?(view, "#search-card-hit")
    end

    test "a card on an epic's board is offered in the strip, with its board", %{
      conn: conn,
      board: board,
      wanted: wanted
    } do
      {:ok, template} = Boards.Templates.find_template(nil, "Simple")
      {:ok, sub} = sub_board(wanted, template)
      sub = Boards.get_board!(sub.id)
      subcard = card_fixture(hd(sub.columns), %{"title" => "Style the form"})

      {:ok, view, _} = live(conn, ~p"/boards/#{board}")
      view |> form("#board-search", %{"q" => "#{subcard.id}"}) |> render_change()

      assert has_element?(
               view,
               ~s{#search-card-hit[href="/boards/#{sub.id}/cards/#{subcard.id}"]},
               "Style the form"
             )

      assert has_element?(view, "#search-card-hit", "##{subcard.id}")
      assert has_element?(view, "#search-card-hit", sub.name)

      render_click(view, "clear_filters")
      refute has_element?(view, "#search-card-hit")
    end

    test "words, an archived card and a card outside the tree offer nothing", %{
      conn: conn,
      board: board,
      user: user,
      wanted: wanted
    } do
      {:ok, template} = Boards.Templates.find_template(nil, "Simple")
      {:ok, sub} = sub_board(wanted, template)
      sub = Boards.get_board!(sub.id)
      gone = card_fixture(hd(sub.columns), %{"title" => "Old idea"})
      {:ok, _} = Boards.Cards.archive_card(gone)

      elsewhere = board_fixture(%{"name" => "Elsewhere"}, owner: user, derive_keys: true)
      far = card_fixture(hd(Boards.get_board!(elsewhere.id).columns), %{"title" => "Far away"})

      {:ok, view, _} = live(conn, ~p"/boards/#{board}")

      for q <- ["login", "##{gone.id}", "##{far.id}"] do
        view |> form("#board-search", %{"q" => q}) |> render_change()
        refute has_element?(view, "#search-card-hit"), "expected no hit for #{inspect(q)}"
      end
    end

    test "a reader of the board is offered its subcards too", %{
      board: board,
      user: user,
      wanted: wanted
    } do
      {:ok, template} = Boards.Templates.find_template(nil, "Simple")
      {:ok, sub} = sub_board(wanted, template)

      subcard =
        card_fixture(hd(Boards.get_board!(sub.id).columns), %{"title" => "Style the form"})

      reader = user_fixture("reader@example.com")
      {:ok, _} = Access.grant(board, reader, "read", user)

      {:ok, view, _} = live(log_in_user(build_conn(), reader), ~p"/boards/#{board}")
      view |> form("#board-search", %{"q" => "##{subcard.id}"}) |> render_change()

      assert has_element?(view, "#search-card-hit", "Style the form")
    end
  end

  describe "Boards.Links.card_elsewhere_in_tree/3" do
    setup %{wanted: wanted, backlog: backlog} do
      {:ok, template} = Boards.Templates.find_template(nil, "Simple")
      {:ok, sub} = sub_board(wanted, template)
      sub = Boards.get_board!(sub.id)

      %{
        sub: sub,
        subcard: card_fixture(hd(sub.columns), %{"title" => "Style the form"}),
        backlog: backlog
      }
    end

    test "finds a subcard by id, #id or link", %{
      user: user,
      board: board,
      sub: sub,
      subcard: subcard
    } do
      for q <- ["#{subcard.id}", "##{subcard.id}", "/boards/#{sub.id}/cards/#{subcard.id}"] do
        assert %{id: id} = Boards.Links.card_elsewhere_in_tree(user, board, q)
        assert id == subcard.id
      end
    end

    test "nothing for a card on the board itself, words, or nothing typed", %{
      user: user,
      board: board,
      wanted: wanted
    } do
      assert Boards.Links.card_elsewhere_in_tree(user, board, "##{wanted.id}") == nil
      assert Boards.Links.card_elsewhere_in_tree(user, board, "Style") == nil
      assert Boards.Links.card_elsewhere_in_tree(user, board, "") == nil
      assert Boards.Links.card_elsewhere_in_tree(user, board, nil) == nil
    end

    test "nothing for someone who cannot read the card", %{board: board, subcard: subcard} do
      stranger = user_fixture("stranger@example.com")
      assert Boards.Links.card_elsewhere_in_tree(stranger, board, "##{subcard.id}") == nil
      assert Boards.Links.card_elsewhere_in_tree(nil, board, "##{subcard.id}") == nil
    end
  end
end
