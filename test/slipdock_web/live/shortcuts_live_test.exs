defmodule SlipdockWeb.ShortcutsLiveTest do
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures
  alias Slipdock.Boards
  alias Slipdock.Boards.Board

  describe "a board's shortcut key" do
    test "is taken from the name, and steps aside when one is claimed" do
      a = board_fixture(%{"name" => "Marketing"}, derive_keys: true)
      b = board_fixture(%{"name" => "Money"}, derive_keys: true)
      c = board_fixture(%{"name" => "Mmm"}, derive_keys: true)

      assert a.shortcut == "m"
      # "Money" wants m, which is gone, so its next letter takes it.
      assert b.shortcut == "o"
      # "Mmm" has nothing left of its own; the home keys take over.
      assert c.shortcut == "a"
    end

    test "sub-boards get none — the switcher only lists boards" do
      board = board_fixture(%{"name" => "Roadmap"}, derive_keys: true)
      [column | _] = board.columns
      card = card_fixture(column, %{"title" => "Epic"})
      {:ok, t} = Boards.find_template("Simple")
      {:ok, sub} = Boards.create_sub_board(card, t)

      assert sub.shortcut == nil
      assert Boards.get_board!(board.id).shortcut == "r"
    end

    test "can be set by hand, and clearing it asks for a fresh one" do
      board = board_fixture(%{"name" => "Roadmap"}, derive_keys: true)

      {:ok, board} = Boards.update_board(board, %{"shortcut" => "Z"})
      assert board.shortcut == "z"

      {:ok, board} = Boards.update_board(board, %{"shortcut" => ""})
      assert board.shortcut == "r"

      # An update that says nothing about it keeps the key the board has.
      {:ok, board} = Boards.update_board(board, %{"name" => "Plans"})
      assert board.shortcut == "r"
    end

    test "is refused when it is another board's, or is not a key" do
      board_fixture(%{"name" => "Roadmap"}, derive_keys: true)
      other = board_fixture(%{"name" => "Plans"}, derive_keys: true)

      assert {:error, changeset} = Boards.update_board(other, %{"shortcut" => "r"})
      assert {"is already used by another board", _} = changeset.errors[:shortcut]

      assert {:error, changeset} = Boards.update_board(other, %{"shortcut" => "abc"})
      assert changeset.errors[:shortcut]
    end

    test "the generator falls back to pairs once the singles run out" do
      taken = Board.shortcut_from_name("x", []) |> List.wrap()

      taken =
        Enum.reduce(
          1..40,
          MapSet.new(taken),
          &MapSet.put(&2, Board.shortcut_from_name("#{&1}zzz", &2))
        )

      fresh = Board.shortcut_from_name("zzz", taken)
      assert String.length(fresh) == 2
      refute MapSet.member?(taken, fresh)
    end
  end

  describe "the palettes" do
    setup %{conn: conn} do
      board = board_fixture(%{"name" => "Roadmap"}, derive_keys: true)
      {:ok, view, _} = live(conn, ~p"/boards/#{board}")
      %{board: board, view: view}
    end

    test "b lists every board you can open, with its key", %{view: view, board: board} do
      other = board_fixture(%{"name" => "Personal"}, derive_keys: true)

      html = render_hook(view, "shortcut_panel", %{"panel" => "boards"})
      assert html =~ "Switch board"
      assert has_element?(view, ~s{#key-palette[data-key-capture]})
      assert has_element?(view, ~s{#key-palette a[data-shortcut="#{board.shortcut}"]}, board.name)
      assert has_element?(view, ~s{#key-palette a[data-shortcut="#{other.shortcut}"]}, other.name)

      # The same key again closes it.
      refute render_hook(view, "shortcut_panel", %{"panel" => "boards"}) =~ "Switch board"
    end

    test "v lists this board's views, marking the one you are on", %{view: view} do
      render_hook(view, "shortcut_panel", %{"panel" => "views"})
      assert has_element?(view, ~s{#key-palette a[data-shortcut="s"]}, "Swimlanes")
      assert has_element?(view, ~s{#key-palette a[data-shortcut="b"].font-medium}, "Board")
    end

    test "? shows the catalogue, and Escape closes it", %{view: view} do
      html = render_hook(view, "shortcut_panel", %{"panel" => "help"})
      assert html =~ "Keyboard shortcuts"
      assert html =~ "Switch board — then the board&#39;s own key"
      assert html =~ "type a label to pick it up and move it"
      assert html =~ "Attachments · Checklist · Subcards"

      refute render_hook(view, "close_shortcuts", %{}) =~ "Keyboard shortcuts"
    end

    test "the catalogue offers hjkl alongside the arrows on the board", %{view: view} do
      html = render_hook(view, "shortcut_panel", %{"panel" => "help"})
      assert html =~ "j k ↑ ↓"
      assert html =~ "h l ← →"
    end

    test "Ctrl-P lists commands, and typing narrows them", %{view: view, board: board} do
      html = render_hook(view, "shortcut_panel", %{"panel" => "command"})
      assert html =~ "Commands"
      assert has_element?(view, ~s{#key-palette[data-key-capture="filter"]})
      assert has_element?(view, ~s{#palette-rows a}, "My work")
      assert has_element?(view, ~s{#palette-rows a}, "Board settings — Roadmap")
      assert has_element?(view, ~s{#palette-rows a}, board.name)

      # The label wins over the keywords, and the first row is the one Enter
      # would follow.
      render_hook(view, "palette_filter", %{"q" => "work"})
      assert has_element?(view, ~s{#palette-rows [data-row][data-on]}, "My work")
      refute has_element?(view, ~s{#palette-rows [data-row]}, "Templates")
    end

    test "a command that does something rather than going somewhere", %{view: view} do
      render_hook(view, "shortcut_panel", %{"panel" => "command"})
      render_hook(view, "palette_filter", %{"q" => "quick add"})
      assert has_element?(view, ~s{#palette-rows button[data-row][data-on]}, "Quick add a card")
    end

    test "the arrows walk the rows, and wrap", %{view: view, board: board} do
      render_hook(view, "shortcut_panel", %{"panel" => "command"})
      render_hook(view, "palette_filter", %{"q" => board.name})

      # The board itself first, then its pages in alphabetical order.
      assert on_row(view, ~p"/boards/#{board}")
      render_hook(view, "palette_move", %{"dir" => "down"})
      assert on_row(view, ~p"/boards/#{board}/activity")

      # Up from the top lands on the bottom.
      render_hook(view, "palette_move", %{"dir" => "up"})
      render_hook(view, "palette_move", %{"dir" => "up"})
      assert on_row(view, ~p"/boards/#{board}/tags")
    end

    test "Ctrl-O finds cards on any board you can open", %{view: view, board: board} do
      other = board_fixture(%{"name" => "Personal"}, derive_keys: true)
      card = card_fixture(hd(board.columns), %{"title" => "Query parser"})
      far = card_fixture(hd(other.columns), %{"title" => "Query the far board"})

      html = render_hook(view, "shortcut_panel", %{"panel" => "find"})
      assert html =~ "Find a card"
      assert html =~ "Type to find a card on any board."

      render_hook(view, "palette_filter", %{"q" => "query"})
      assert has_element?(view, ~s{#palette-rows a[href="/boards/#{board.id}/cards/#{card.id}"]})
      assert has_element?(view, ~s{#palette-rows a[href="/boards/#{other.id}/cards/#{far.id}"]})

      assert render_hook(view, "palette_filter", %{"q" => "nothing like it"}) =~ "No cards match."
    end

    test "a card on a board you cannot open is not found", %{view: view} do
      stranger = user_fixture("stranger@example.com")
      theirs = board_fixture(%{"name" => "Theirs"}, owner: stranger, derive_keys: true)
      card_fixture(hd(theirs.columns), %{"title" => "Secret parser"})

      render_hook(view, "shortcut_panel", %{"panel" => "find"})
      assert render_hook(view, "palette_filter", %{"q" => "secret"}) =~ "No cards match."
    end

    test "h goes home", %{view: view} do
      render_hook(view, "go_home", %{})
      assert_redirect(view, ~p"/")
    end

    test "a page with nowhere to jump to offers no view palette", %{conn: conn} do
      {:ok, work, _} = live(conn, ~p"/work")
      assert has_element?(work, "#keys[data-views=false]")
    end
  end

  # Is the row Enter would follow the one going to `path`?
  defp on_row(view, path) do
    has_element?(view, ~s{#palette-rows [data-row][data-on][href="#{path}"]})
  end

  test "the board settings form offers the key", %{conn: conn} do
    board = board_fixture(%{"name" => "Roadmap"}, derive_keys: true)
    {:ok, view, _} = live(conn, ~p"/boards/#{board}/settings")

    assert has_element?(view, ~s{#board-form input[name="board[shortcut]"]})

    view
    |> form("#board-form",
      board: %{"name" => board.name, "code" => board.code, "shortcut" => "zz"}
    )
    |> render_submit()

    assert Boards.get_board!(board.id).shortcut == "zz"
  end
end
