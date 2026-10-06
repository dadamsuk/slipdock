defmodule SlipdockWeb.SearchBoxLiveTest do
  @moduledoc """
  The board toolbars' search box (#344). On a phone it folds away behind a
  one-tap magnifying glass; a box with a query in it is never folded, so a
  filter is never hidden. Which of the two shows is the stylesheet's job
  (`.search-box` / `.search-open`, `sm:hidden` on the button), so these
  tests check the classes and the button's client-side command.
  """
  use SlipdockWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  setup do
    board = board_fixture(%{"name" => "Searchable"})
    [_backlog, todo | _] = board.columns
    card_fixture(todo, %{"title" => "Fix the login page"})
    card_fixture(todo, %{"title" => "Write the release notes"})
    %{board: board}
  end

  # The button's phx-click, decoded: a list of [op, args] pairs.
  defp click_ops(view, selector) do
    [_, click] = Regex.run(~r/phx-click="([^"]*)"/, view |> element(selector) |> render())
    click |> String.replace("&quot;", ~s(")) |> Jason.decode!()
  end

  describe "the board view" do
    test "with no query, the box is folded behind a phone-only button", %{
      conn: conn,
      board: board
    } do
      {:ok, view, _} = live(conn, ~p"/boards/#{board}")

      assert has_element?(view, "#board-search-box.search-box #board-search input[name=q]")
      refute has_element?(view, "#board-search-box.search-open")

      assert has_element?(
               view,
               ~s(#board-search-box-toggle.sm\\:hidden[aria-label="Search cards"])
             )

      assert has_element?(view, ~s(#board-search-box-toggle[aria-controls="board-search-box"]))
    end

    test "the button opens the box, hides itself and focuses the input", %{
      conn: conn,
      board: board
    } do
      {:ok, view, _} = live(conn, ~p"/boards/#{board}")

      ops = click_ops(view, "#board-search-box-toggle")

      assert ["add_class", %{"names" => ["search-open"], "to" => "#board-search-box"}] =
               Enum.find(ops, &match?(["add_class", _], &1))

      assert ["hide", %{"to" => "#board-search-box-toggle"}] =
               Enum.find(ops, &match?(["hide", _], &1))

      assert ["focus", %{"to" => "#board-search-box input"}] =
               Enum.find(ops, &match?(["focus", _], &1))

      # Purely client-side: nothing goes to the server.
      refute Enum.any?(ops, &match?(["push", _], &1))
    end

    test "a query keeps the box open, drops the button, and still filters", %{
      conn: conn,
      board: board
    } do
      {:ok, view, _} = live(conn, ~p"/boards/#{board}")

      html = view |> form("#board-search", %{"q" => "login"}) |> render_change()

      assert has_element?(view, "#board-search-box.search-open")
      refute has_element?(view, "#board-search-box-toggle")
      assert html =~ "Fix the login page"
      refute html =~ "Write the release notes"

      # Cleared, it folds back to the button.
      view |> form("#board-search", %{"q" => ""}) |> render_change()
      refute has_element?(view, "#board-search-box.search-open")
      assert has_element?(view, "#board-search-box-toggle")
    end
  end

  describe "the swimlane and table toolbars" do
    test "fold the box the same way", %{conn: conn, board: board} do
      for path <- [~p"/boards/#{board}/swimlanes", ~p"/boards/#{board}/table"] do
        {:ok, view, _} = live(conn, path)

        assert has_element?(view, "#swim-config #swim-search.search-box input[name=q]")
        refute has_element?(view, "#swim-search.search-open")
        assert has_element?(view, "#swim-search-toggle.sm\\:hidden")

        ops = click_ops(view, "#swim-search-toggle")

        assert ["focus", %{"to" => "#swim-search input"}] =
                 Enum.find(ops, &match?(["focus", _], &1))
      end
    end

    test "a query in the address keeps the box open", %{conn: conn, board: board} do
      {:ok, view, _} = live(conn, ~p"/boards/#{board}/table?q=login")

      assert has_element?(view, "#swim-search.search-open input[name=q][value=login]")
      refute has_element?(view, "#swim-search-toggle")
    end
  end
end
