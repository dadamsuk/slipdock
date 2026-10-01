defmodule SlipdockWeb.KeyboardLiveTest do
  use SlipdockWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures
  alias Slipdock.Boards

  setup do
    board = board_fixture(%{"name" => "Hints"})
    [backlog, todo | _] = board.columns
    a = card_fixture(backlog, %{"title" => "Alpha"})
    b = card_fixture(backlog, %{"title" => "Bravo"})
    c = card_fixture(backlog, %{"title" => "Charlie"})

    %{board: reload(board), backlog: backlog, todo: todo, a: a, b: b, c: c}
  end

  # The titles in a list, in the order the board shows them.
  defp titles(board, column_id) do
    Boards.get_board!(board.id).columns
    |> Enum.find(&(&1.id == column_id))
    |> Map.fetch!(:cards)
    |> Enum.sort_by(& &1.position)
    |> Enum.map(& &1.title)
  end

  defp hold(view, card),
    do: render_hook(view, "focus_card", %{"id" => to_string(card.id), "hold" => true})

  defp point(view, column), do: render_hook(view, "focus_column", %{"id" => to_string(column.id)})
  defp arrow(view, dir), do: render_hook(view, "focus_move", %{"dir" => dir})

  describe "the board's own keys" do
    test "the hook is mounted, and only offers moves where they make sense",
         %{conn: conn, board: board} do
      {:ok, view, _} = live(conn, ~p"/boards/#{board}")

      assert has_element?(
               view,
               "#board-keys[phx-hook=BoardKeys][data-board=true][data-move=true]"
             )

      # Cards and lists are the board view's; the other views get labels only.
      {:ok, swim, _} = live(conn, ~p"/boards/#{board}/swimlanes")
      assert has_element?(swim, "#board-keys[data-board=false][data-move=false]")
    end

    test "read-only access is offered no moves", %{board: board, user: owner} do
      reader = user_fixture("reader@example.com")
      {:ok, _} = Slipdock.Access.grant(board, reader, "read", owner)

      {:ok, view, _} = live(conn_as(reader), ~p"/boards/#{board}")
      assert has_element?(view, "#board-keys[data-board=true][data-move=false]")
    end
  end

  describe "an open card's keys" do
    setup %{conn: conn, board: board, a: a} do
      {:ok, view, _} = live(conn, ~p"/boards/#{board}/cards/#{a.id}")
      %{view: view}
    end

    test "the dialog takes the keyboard", %{view: view} do
      assert has_element?(view, "#card-modal[phx-hook=CardKeys][data-card-keys]")
    end

    test "every section carries its key", %{view: view} do
      for {key, label} <- [
            {"f", "Flags"},
            {"t", "Tags"},
            {"d", "Description"},
            {"a", "Attachments"},
            {"e", "Checklist"},
            {"s", "Subcards"},
            {"p", "Dependencies"},
            {"n", "Links"},
            {"c", "Comments"}
          ] do
        assert has_element?(view, ~s{#card-modal [data-section-key="#{key}"]}),
               "no section keyed #{key} for #{label}"
      end
    end

    test "each heading underlines the letter that reaches it", %{view: view} do
      html = render(view)

      # Not always the first letter: Comments has C, and hjkl move about, so
      # Checklist is down to its E and Links to its N.
      assert html =~ ~s{<u class="underline decoration-1 underline-offset-2">D</u>escription}
      assert html =~ ~s{Ch<u class="underline decoration-1 underline-offset-2">e</u>cklist}
      assert html =~ ~s{De<u class="underline decoration-1 underline-offset-2">p</u>endencies}
      assert html =~ ~s{Li<u class="underline decoration-1 underline-offset-2">n</u>ks}
      assert html =~ ~s{<u class="underline decoration-1 underline-offset-2">C</u>omments}
    end

    test "no two sections share a key", %{view: view} do
      keys =
        render(view)
        |> then(&Regex.scan(~r/data-section-key="([a-z])"/, &1))
        |> Enum.map(&List.last/1)

      assert length(keys) == length(Enum.uniq(keys))
      # hjkl move about the card, so no section may claim one of them.
      assert keys -- ~w(h j k l) == keys
    end
  end

  describe "picking a card up (J)" do
    test "it is ringed and named, and dropping lets go", %{conn: conn, board: board, a: a} do
      {:ok, view, _} = live(conn, ~p"/boards/#{board}")

      html = hold(view, a)
      assert html =~ "Moving “Alpha”"
      assert has_element?(view, "#card-#{a.id}[data-focus=held]")
      assert has_element?(view, "#board-keys[data-focus=hold]")

      # Enter (and Escape) put the card down but keep the keyboard on it.
      html = render_hook(view, "focus_end", %{})
      assert html =~ "On “Alpha”"
      assert has_element?(view, "#card-#{a.id}[data-focus=cursor]")

      # A second one lets go of the board altogether.
      html = render_hook(view, "focus_end", %{})
      refute html =~ "Moving “Alpha”"
      refute html =~ "On “Alpha”"
      refute has_element?(view, "#board-keys[data-focus]")
    end

    test "the strip offers hjkl as well as the arrows", %{conn: conn, board: board, a: a} do
      {:ok, view, _} = live(conn, ~p"/boards/#{board}")

      assert hold(view, a) =~ "h l or ← → list · j k or ↑ ↓ order"
      assert render_hook(view, "focus_end", %{}) =~ "h j k l or arrows move"
    end

    test "a card that is not on the board cannot be picked up", %{conn: conn, board: board} do
      {:ok, view, _} = live(conn, ~p"/boards/#{board}")
      refute render_hook(view, "focus_card", %{"id" => "999999", "hold" => true}) =~ "Moving"
      refute render_hook(view, "focus_card", %{"id" => "nope", "hold" => true}) =~ "Moving"
    end

    test "read-only access cannot carry a card", %{board: board, user: owner, a: a} do
      reader = user_fixture("reader@example.com")
      {:ok, _} = Slipdock.Access.grant(board, reader, "read", owner)

      {:ok, view, _} = live(conn_as(reader), ~p"/boards/#{board}")
      # The card can still be pointed at — it just is not picked up.
      assert hold(view, a) =~ "On “Alpha”"
      refute has_element?(view, "#board-keys[data-focus=hold]")
    end

    test "the arrows reorder within a list and stop at its ends",
         %{conn: conn, board: board, backlog: backlog, b: b} do
      {:ok, view, _} = live(conn, ~p"/boards/#{board}")
      hold(view, b)

      assert titles(board, backlog.id) == ["Alpha", "Bravo", "Charlie"]

      arrow(view, "up")
      assert titles(board, backlog.id) == ["Bravo", "Alpha", "Charlie"]

      # Already at the top: the arrow is a no-op rather than a wrap.
      arrow(view, "up")
      assert titles(board, backlog.id) == ["Bravo", "Alpha", "Charlie"]

      arrow(view, "down")
      arrow(view, "down")
      assert titles(board, backlog.id) == ["Alpha", "Charlie", "Bravo"]

      # And the bottom holds too.
      arrow(view, "down")
      assert titles(board, backlog.id) == ["Alpha", "Charlie", "Bravo"]
    end

    test "left and right carry the card between lists, keeping its place",
         %{conn: conn, board: board, backlog: backlog, todo: todo, b: b} do
      card_fixture(todo, %{"title" => "Delta"})

      {:ok, view, _} = live(conn, ~p"/boards/#{board}")
      hold(view, b)

      # Bravo sits second in the backlog, so it lands second in the next list.
      arrow(view, "right")
      assert titles(board, backlog.id) == ["Alpha", "Charlie"]
      assert titles(board, todo.id) == ["Delta", "Bravo"]

      # The card stays held across the move, so the arrows keep working.
      assert render(view) =~ "Moving “Bravo”"

      # …and back, again into the place it held in the list it came from.
      arrow(view, "left")
      assert titles(board, todo.id) == ["Delta"]
      assert titles(board, backlog.id) == ["Alpha", "Bravo", "Charlie"]

      # The first list has nothing to its left.
      arrow(view, "left")
      assert titles(board, backlog.id) == ["Alpha", "Bravo", "Charlie"]
    end

    test "opening a card lets go of the held one", %{conn: conn, board: board, a: a} do
      {:ok, view, _} = live(conn, ~p"/boards/#{board}")
      assert hold(view, a) =~ "Moving “Alpha”"

      render_hook(view, "open_card", %{"id" => to_string(a.id)})
      refute render(view) =~ "Moving “Alpha”"
    end
  end

  describe "stepping through a list (c)" do
    test "it lands on the list's first card and walks from there",
         %{conn: conn, board: board, backlog: backlog, todo: todo, a: a, b: b} do
      card_fixture(todo, %{"title" => "Delta"})
      {:ok, view, _} = live(conn, ~p"/boards/#{board}")

      assert point(view, backlog) =~ "On “Alpha”"
      assert has_element?(view, "#card-#{a.id}[data-focus=cursor]")
      assert has_element?(view, "#board-keys[data-focus=point]")

      assert arrow(view, "down") =~ "On “Bravo”"
      assert arrow(view, "up") =~ "On “Alpha”"

      # The ends hold, here too.
      assert arrow(view, "up") =~ "On “Alpha”"

      # Left and right step to the list either side, and the cards stay put.
      assert arrow(view, "right") =~ "On “Delta”"
      assert titles(board, backlog.id) == ["Alpha", "Bravo", "Charlie"]
      assert titles(board, todo.id) == ["Delta"]

      assert arrow(view, "left") =~ "On “Alpha”"
      refute has_element?(view, "#card-#{b.id}[data-focus]")
    end

    test "a shorter list takes the nearest place it has",
         %{conn: conn, board: board, backlog: backlog, todo: todo} do
      card_fixture(todo, %{"title" => "Delta"})
      {:ok, view, _} = live(conn, ~p"/boards/#{board}")

      point(view, backlog)
      arrow(view, "down")
      assert arrow(view, "down") =~ "On “Charlie”"
      # To Do has one card, so the third place becomes the first.
      assert arrow(view, "right") =~ "On “Delta”"
    end

    test "an empty list is still somewhere to stand, and to add from",
         %{conn: conn, board: board, todo: todo} do
      {:ok, view, _} = live(conn, ~p"/boards/#{board}")

      assert point(view, todo) =~ "On “an empty list”"
      refute has_element?(view, ".kanban-card[data-focus]")

      # "c" again opens that list's add row and hands the keyboard over to it.
      html = render_hook(view, "focus_add", %{})
      assert html =~ "Card title, then Enter"
      assert has_element?(view, "#quick-add-#{todo.id}-0")
      refute has_element?(view, "#board-keys[data-focus]")
    end

    test "the card pointed at can be opened, or picked up",
         %{conn: conn, board: board, backlog: backlog, a: a} do
      {:ok, view, _} = live(conn, ~p"/boards/#{board}")
      point(view, backlog)

      assert render_hook(view, "focus_hold", %{}) =~ "Moving “Alpha”"

      point(view, backlog)
      render_hook(view, "focus_open", %{})
      assert_patched(view, ~p"/boards/#{board}/cards/#{a.id}")
    end
  end
end
