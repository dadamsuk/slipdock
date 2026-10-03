defmodule SlipdockWeb.BoardIndexLiveTest do
  @moduledoc """
  The “Your boards” page: the two layouts, the order, and archiving a board
  from the list.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Access, Accounts, Boards}

  setup %{user: user} do
    a = board_fixture(%{"name" => "Alpha"}, owner: user)
    b = board_fixture(%{"name" => "Bravo"}, owner: user)
    c = board_fixture(%{"name" => "Charlie"}, owner: user)
    %{a: a, b: b, c: c}
  end

  defp listed(html) do
    Regex.scan(~r/id="board-(\d+)"/, html) |> Enum.map(fn [_, id] -> String.to_integer(id) end)
  end

  describe "the compact layout" do
    test "swaps the cards for a table, and is remembered", %{conn: conn, user: user} do
      {:ok, view, html} = live(conn, ~p"/")
      refute html =~ "<table"

      html = view |> element("button[phx-value-layout=compact]") |> render_click()
      assert html =~ "<table"
      assert Accounts.get_user!(user.id).board_layout == "compact"

      # Still a table on the way back in.
      {:ok, _view, html} = live(conn, ~p"/")
      assert html =~ "<table"

      html = view |> element("button[phx-value-layout=grid]") |> render_click()
      refute html =~ "<table"
      assert Accounts.get_user!(user.id).board_layout == "grid"
    end

    test "lists every board it can see", %{conn: conn, a: a, b: b, c: c} do
      {:ok, view, _} = live(conn, ~p"/")
      html = view |> element("button[phx-value-layout=compact]") |> render_click()

      assert listed(html) == [a.id, b.id, c.id]
      assert html =~ "Alpha"
      assert html =~ "Charlie"
    end
  end

  describe "the order" do
    test "can be changed board by board, and is remembered", %{conn: conn, user: user, c: c} do
      {:ok, view, html} = live(conn, ~p"/")
      assert listed(html) == Enum.map(Access.list_boards(user), & &1.id)

      html = render_click(view, "nudge", %{"id" => to_string(c.id), "dir" => "up"})
      [_, second, _] = listed(html)
      assert second == c.id

      {:ok, _view, html} = live(conn, ~p"/")
      assert Enum.at(listed(html), 1) == c.id
    end

    test "a drag drops a board in front of another", %{conn: conn, a: a, c: c} do
      {:ok, view, _} = live(conn, ~p"/")

      html =
        render_hook(view, "reorder", %{
          "id" => to_string(c.id),
          "from" => "boards",
          "to" => "boards",
          "before" => to_string(a.id)
        })

      assert hd(listed(html)) == c.id
    end

    test "another sort reorders the list without losing the person's own", ctx do
      %{conn: conn, user: user, a: a, b: b, c: c} = ctx
      {:ok, view, _} = live(conn, ~p"/")

      render_click(view, "nudge", %{"id" => to_string(c.id), "dir" => "up"})

      html =
        view
        |> form("#board-sort", %{"sort" => "name"})
        |> render_change()

      assert listed(html) == [a.id, b.id, c.id]
      assert Accounts.get_user!(user.id).board_sort == "name"

      # Going back to "my order" finds it where it was left.
      html = view |> form("#board-sort", %{"sort" => "manual"}) |> render_change()
      assert listed(html) == [a.id, c.id, b.id]
    end

    test "is this person's alone", %{conn: conn, user: user, c: c} do
      other = user_fixture("other@example.com")
      shared = board_fixture(%{"name" => "Shared"}, owner: other)
      {:ok, _} = Access.grant(shared, user, "read", other)

      {:ok, view, _} = live(conn, ~p"/")
      render_click(view, "nudge", %{"id" => to_string(c.id), "dir" => "up"})

      # The other person's index is untouched.
      assert Enum.map(Access.list_boards(other), & &1.id) == [shared.id]
      assert Boards.board_order(other) == %{}
    end
  end

  describe "a board somebody else owns" do
    setup %{user: user} do
      other = user_fixture("nadia@example.com")
      {:ok, other} = Accounts.update_profile(other, %{"name" => "Nadia"})
      shared = board_fixture(%{"name" => "Shared"}, owner: other)
      {:ok, _} = Access.grant(shared, user, "read", other)
      %{other: other, shared: shared}
    end

    test "names its owner on the cards", %{conn: conn, shared: shared} do
      {:ok, _view, html} = live(conn, ~p"/")

      assert shared.id in listed(html)
      assert html =~ "shared by Nadia"
    end

    test "names its owner in the table too", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/")
      html = view |> element("button[phx-value-layout=compact]") |> render_click()

      assert html =~ "<table"
      assert html =~ "shared by Nadia"
    end
  end

  test "says nothing about an owner when every board is yours", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/")

    refute html =~ "shared by"
  end

  describe "archiving from the list" do
    test "takes the board off the list and offers it back", %{conn: conn, user: user, b: b} do
      {:ok, view, _} = live(conn, ~p"/")

      html = render_click(view, "archive", %{"id" => to_string(b.id)})
      refute b.id in listed(html)
      assert html =~ "Archived"

      html = render_click(view, "toggle_archived", %{})
      assert b.id in listed(html)

      html = render_click(view, "unarchive", %{"id" => to_string(b.id)})
      assert b.id in listed(html)
      refute Slipdock.Boards.Board.archived?(Boards.get_board!(b.id))
      assert b.id in Enum.map(Access.list_boards(user), & &1.id)
    end

    test "is the owner's alone", %{conn: conn, user: user} do
      other = user_fixture("other@example.com")
      shared = board_fixture(%{"name" => "Shared"}, owner: other)
      {:ok, _} = Access.grant(shared, user, "write", other)

      {:ok, view, _} = live(conn, ~p"/")
      html = render_click(view, "archive", %{"id" => to_string(shared.id)})

      assert html =~ "Only the board&#39;s owner can do that."
      refute Slipdock.Boards.Board.archived?(Boards.get_board!(shared.id))
    end

    test "an archived board still opens, and says so", %{conn: conn, b: b} do
      {:ok, _} = Boards.archive_board(b)

      {:ok, _view, html} = live(conn, ~p"/boards/#{b.id}")
      assert html =~ "archived"
    end

    test "an archived board drops out of the board switcher", %{conn: conn, b: b} do
      {:ok, view, _} = live(conn, ~p"/")
      assert render(view) =~ "Bravo"

      {:ok, _} = Boards.archive_board(b)
      {:ok, _view, html} = live(conn, ~p"/work")
      refute html =~ "Bravo"
    end
  end
end
