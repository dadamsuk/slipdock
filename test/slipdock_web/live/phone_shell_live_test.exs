defmodule SlipdockWeb.PhoneShellLiveTest do
  @moduledoc """
  The phone shell (#1717): the board's toolbar keeps to one row, the page
  stops short of the floating dock, Account → Profile stacks, the phone
  card's arrow says what it does, and the header's Commands button wears a
  glyph that isn't a terminal. The measurements themselves are in
  `tools/e2e/phone-shell.sh`; these pin the markup they depend on.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  @dock_room "max-sm:pb-[calc(5.25rem+env(safe-area-inset-bottom))]"

  setup do
    board = board_fixture(%{"name" => "Phone shell", "code" => "phsh"})
    [todo | _] = board.columns
    card = card_fixture(todo, %{"title" => "Ship it"})
    %{board: board, card: card}
  end

  describe "the board's toolbar" do
    test "does not wrap below sm, and closes its gaps", %{conn: conn, board: board} do
      {:ok, view, _} = live(conn, ~p"/boards/#{board}")

      assert has_element?(view, "#board-toolbar.max-sm\\:flex-nowrap.max-sm\\:gap-x-1")
      # Select and the saved views stay on the row: they don't shrink out of it.
      assert has_element?(view, "#board-toolbar > div.ml-auto.shrink-0 #select-mode-toggle")
    end

    test "Display is its icon on a phone, and still says what it is", %{
      conn: conn,
      board: board
    } do
      {:ok, view, _} = live(conn, ~p"/boards/#{board}")

      assert has_element?(
               view,
               "#display-menu [role=button].max-sm\\:btn-square[aria-label='Display options']"
             )

      assert has_element?(view, "#display-menu [role=button] span.hidden.sm\\:inline", "Display")
    end

    test "Select names itself without its word", %{conn: conn, board: board} do
      {:ok, view, _} = live(conn, ~p"/boards/#{board}")

      assert has_element?(view, "#select-mode-toggle[aria-label='Select several cards']")
      assert has_element?(view, "#select-mode-toggle span.hidden.sm\\:inline", "Select")
    end

    test "a reader has no Select, and the row is still one", %{board: board} do
      reader = user_fixture("phone-reader@example.com")
      {:ok, _} = Slipdock.Access.grant(board, reader, "read", board_owner(board))
      {:ok, view, _} = live(log_in_user(build_conn(), reader), ~p"/boards/#{board}")

      assert has_element?(view, "#board-toolbar.max-sm\\:flex-nowrap")
      refute has_element?(view, "#select-mode-toggle")
    end
  end

  describe "the dock" do
    for path <- ["/", "/work", "/account", :board] do
      test "the page stops short of it on #{inspect(path)}", %{conn: conn, board: board} do
        path = if unquote(path) == :board, do: ~p"/boards/#{board}", else: unquote(path)
        {:ok, view, _} = live(conn, path)

        assert view |> element("main") |> render() =~ @dock_room
        assert has_element?(view, "#mobile-bar")
      end
    end

    test "signed out there is no dock, and no room kept for one" do
      html = build_conn() |> get(~p"/login") |> html_response(200)

      refute html =~ ~s(id="mobile-bar")
      refute html =~ @dock_room
    end
  end

  describe "Account → Profile" do
    test "stacks its fields below sm", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/account")

      assert has_element?(view, "#profile-form.field-row.field-row-stack")
      assert has_element?(view, "#profile-form input[name$='[name]']")
    end

    test "the stacking rule is in the stylesheet, below sm only" do
      css = File.read!("assets/css/app.css")

      assert css =~
               ~r/@media \(width < 40rem\) \{\s*\.field-row-stack \{\s*flex-direction: column;/
    end
  end

  describe "the phone card's arrow" do
    test "names the card and what it does", %{conn: conn, board: board, card: card} do
      {:ok, view, _} = live(conn, ~p"/boards/#{board}")

      assert has_element?(
               view,
               "button[title='Move to another list'][aria-label='Move “#{card.title}” to another list']"
             )
    end
  end

  describe "the header's Commands button" do
    test "is a bolt, not a terminal, and names its key", %{conn: conn, board: board} do
      {:ok, view, _} = live(conn, ~p"/boards/#{board}")

      assert has_element?(view, "#commands-open[aria-label='Commands (Ctrl-P)'] .hero-bolt")
      refute has_element?(view, "#topbar .hero-command-line")
    end
  end

  describe "the home list on a phone" do
    setup %{conn: conn, user: user, board: board} do
      {:ok, view, _} = live(conn, ~p"/")
      render_click(view, "set_layout", %{"layout" => "compact"})
      [_, todo | _] = board.columns

      {:ok, mb} =
        Slipdock.Multiboard.create_saved(user, %{"name" => "Queue"}, %{lists: [todo.id]})

      {:ok, view, _} = live(conn, ~p"/")
      %{view: view, mb: mb}
    end

    test "folds lists, cards and done into a line under the name", %{view: view, board: board} do
      for col <- ~w(Lists Cards Done) do
        assert has_element?(view, "thead th.hidden.sm\\:table-cell", col)
      end

      assert has_element?(
               view,
               "#board-#{board.id} [data-role=board-row-meta].sm\\:hidden",
               "#{length(board.columns)} lists · 1 card · 0% done"
             )
    end

    test "says how much is done, and nothing about it on an empty board", %{
      conn: conn,
      user: user,
      board: board,
      card: card
    } do
      {:ok, _} = Slipdock.Boards.Cards.toggle_completed(card)
      empty = board_fixture(%{"name" => "Empty", "code" => "phsh2"}, owner: user)
      {:ok, view, _} = live(conn, ~p"/")

      assert has_element?(
               view,
               "#board-#{board.id} [data-role=board-row-meta]",
               "1 card · 100% done"
             )

      assert has_element?(view, "#board-#{empty.id} [data-role=board-row-meta]", "0 cards")
      refute has_element?(view, "#board-#{empty.id} [data-role=board-row-meta]", "done")
    end

    test "a multiboard's row has the same cells as the header, and its own line", %{
      view: view,
      mb: mb
    } do
      thead = view |> element("thead") |> render()
      row = view |> element("tr#multiboard-#{mb.id}") |> render()
      cells = fn part -> length(Regex.scan(~r/<t[hd][\s>]/, part)) end

      assert cells.(row) == cells.(thead)
      assert has_element?(view, "#multiboard-#{mb.id} [data-role=board-row-meta]", "1 list")
    end
  end

  defp board_owner(board), do: Slipdock.Repo.get!(Slipdock.Accounts.User, board.owner_id)
end
