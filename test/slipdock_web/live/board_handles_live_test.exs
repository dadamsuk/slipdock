defmodule SlipdockWeb.BoardHandlesLiveTest do
  @moduledoc """
  Handles out of the way, Share in view (#1716). A board's code and switcher
  key are for the CLI and the keyboard: they are in the board name's tooltip,
  on a home tile's hover, in the list layout's own column and in a Copy
  board code menu item, never drawn as chips by default. Home tiles have a
  thin colour strip, "Add a new board" is there only while there are no
  boards, and the board toolbar has a Share button.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures
  import Ecto.Query, only: [where: 2]

  alias Slipdock.Multiboard

  # The tile's face with its hover-only handles taken out, as `{html, text}`:
  # what is drawn before the pointer reaches it. (The ⋯ menu is closed.)
  defp at_rest(view, tile) do
    html = view |> element("#{tile} > a") |> render()
    doc = LazyHTML.from_fragment(html)
    hover = doc |> LazyHTML.query("[data-role=tile-handles]") |> LazyHTML.to_html()
    rest = if hover == "", do: html, else: String.replace(LazyHTML.to_html(doc), hover, "")
    {rest, rest |> LazyHTML.from_fragment() |> LazyHTML.text()}
  end

  describe "home tiles" do
    setup %{user: user} do
      board = board_fixture(%{"name" => "Keystone", "code" => "bh1716a"}, owner: user)
      %{board: board}
    end

    test "draw no code or key chip at rest; the code is in the name's tooltip",
         %{conn: conn, user: user, board: board} do
      {:ok, _} = Slipdock.Hotkeys.put(user, board, 4)
      {:ok, view, _} = live(conn, ~p"/")

      {rest, text} = at_rest(view, "#board-#{board.id}")
      assert text =~ "Keystone"
      refute text =~ "bh1716a"
      refute rest =~ "<kbd"
      refute rest =~ "chip"

      # The handles are there for hover and focus, hidden until then.
      assert has_element?(
               view,
               "#board-#{board.id} [data-role=tile-handles].hidden.group-hover\\:inline-flex",
               "bh1716a"
             )

      assert has_element?(view, "#board-#{board.id} [data-role=tile-handles] kbd", board.shortcut)

      assert has_element?(
               view,
               "#board-#{board.id} [data-role=tile-handles] #board-hotkey-#{board.id}"
             )

      title = view |> element("#board-#{board.id} h2 span[title]") |> render()
      assert title =~ "Code: bh1716a"
      assert title =~ "Switcher: b then #{board.shortcut}"
      assert title =~ "Ctrl+Shift+4"
    end

    test "a board with no code or key has a tooltip of just its name", %{conn: conn, user: user} do
      bare = board_fixture(%{"name" => "Bare", "code" => "bh1716b"}, owner: user)

      Slipdock.Repo.update_all(
        where(Slipdock.Boards.Board, id: ^bare.id),
        set: [shortcut: nil, code: nil]
      )

      {:ok, view, _} = live(conn, ~p"/")
      assert has_element?(view, ~s(#board-#{bare.id} h2 span[title="Bare"]))
      refute has_element?(view, "#board-#{bare.id} [data-role=tile-handles] kbd")
      refute has_element?(view, "#copy-code-#{bare.id}")
    end

    test "the colour band is a thin strip, on boards and multiboards",
         %{conn: conn, user: user, board: board} do
      [_, todo | _] = board.columns
      {:ok, mb} = Multiboard.create_saved(user, %{"name" => "Queue"}, %{lists: [todo.id]})
      {:ok, view, _} = live(conn, ~p"/")

      for tile <- ["#board-#{board.id}", "#multiboard-#{mb.id}"] do
        band = view |> element("#{tile} [data-role=tile-band]") |> render()
        assert band =~ "h-1.5"
        refute band =~ ~r/\bsm:h-\d/
        refute band =~ ~r/\bh-(?:[3-9]|\d\d)\b/
      end
    end

    test "the tile's menu copies the board's code", %{conn: conn, board: board} do
      {:ok, view, _} = live(conn, ~p"/")

      assert has_element?(
               view,
               ~s(#copy-code-#{board.id}[phx-hook=CopyText][data-target="board-code-#{board.id}"]),
               "Copy board code"
             )

      assert has_element?(view, "#copy-code-#{board.id} #board-code-#{board.id}", "bh1716a")
    end

    test "a shared board's tile menu offers the copy too, to someone who isn't the owner",
         %{board: board} do
      reader = user_fixture("bh1716-reader@example.com")
      share_fixture(board, reader, "read")

      {:ok, view, _} = live(conn_as(reader), ~p"/")
      assert has_element?(view, "#copy-code-#{board.id}", "Copy board code")
    end

    test "the list layout has a column of its own for the handles",
         %{conn: conn, user: user, board: board} do
      {:ok, _} = Slipdock.Hotkeys.put(user, board, 5)
      {:ok, view, _} = live(conn, ~p"/")
      view |> element("button[phx-value-layout=compact]") |> render_click()

      assert has_element?(view, "th", "Code")
      assert has_element?(view, "#board-#{board.id} td[data-role=board-handles]", "bh1716a")

      assert has_element?(
               view,
               "#board-#{board.id} td[data-role=board-handles] kbd",
               board.shortcut
             )

      assert has_element?(
               view,
               "#board-#{board.id} td[data-role=board-handles] #board-hotkey-#{board.id}"
             )

      # Not beside the name any more: that cell has the name and its tooltip.
      name_cell = view |> element("#board-#{board.id} td a") |> render()
      refute name_cell =~ "<kbd"
      refute name_cell =~ "chip-line"
      assert name_cell =~ "Code: bh1716a"
    end
  end

  describe "Add a new board" do
    test "is the empty page's action when there are no boards at all" do
      lonely = user_fixture("bh1716-none@example.com")
      {:ok, view, _} = live(conn_as(lonely), ~p"/")

      assert has_element?(view, "#new-board-tile", "Add a new board")
      view |> element("#new-board-tile") |> render_click()
      assert has_element?(view, "#new-board")
      refute has_element?(view, "#new-board-tile")
    end

    test "is not shown beside one board: the New board button is the way in", %{
      conn: conn,
      user: user
    } do
      board_fixture(%{"name" => "Only", "code" => "bh1716c"}, owner: user)
      {:ok, view, html} = live(conn, ~p"/")

      refute has_element?(view, "#new-board-tile")
      refute html =~ "Add a new board"
    end

    test "is shown when every board is archived", %{conn: conn, user: user} do
      board = board_fixture(%{"name" => "Put away", "code" => "bh1716d"}, owner: user)
      {:ok, _} = Slipdock.Boards.Arrangement.archive_board(board)
      {:ok, view, _} = live(conn, ~p"/")

      assert has_element?(view, "#new-board-tile", "Add a new board")
      view |> element("#new-board-tile") |> render_click()
      assert has_element?(view, "#new-board")
    end

    test "is the grid's last tile when there are multiboards but no boards" do
      someone = user_fixture("bh1716-mb@example.com")
      other = board_fixture(%{"name" => "Theirs", "code" => "bh1716e"})
      share_fixture(other, someone, "read")
      [_, todo | _] = other.columns
      {:ok, _} = Multiboard.create_saved(someone, %{"name" => "Queue"}, %{lists: [todo.id]})

      # A board shared with them is still a board on their page.
      {:ok, view, _} = live(conn_as(someone), ~p"/")
      refute has_element?(view, "#new-board-tile")

      for grant <- Slipdock.Access.list_grants(other),
          do: {:ok, _} = Slipdock.Access.revoke(grant)

      {:ok, view, _} = live(conn_as(someone), ~p"/")
      assert has_element?(view, "#boards #new-board-tile", "Add a new board")
    end
  end

  describe "the board header" do
    setup %{user: user} do
      %{board: board_fixture(%{"name" => "Keystone", "code" => "bh1716f"}, owner: user)}
    end

    test "draws no code chip; the code and key are in the name's tooltip",
         %{conn: conn, board: board} do
      {:ok, view, _} = live(conn, ~p"/boards/#{board.id}")

      name = view |> element("#board-name") |> render()
      refute name =~ "chip"
      refute name =~ ">bh1716f<"
      assert name =~ ~r/title="[^"]*Code: bh1716f/
      assert name =~ "Switcher: b then #{board.shortcut}"
      refute has_element?(view, "nav .chip", "bh1716f")
    end

    test "for a reader too, after how it is shared", %{board: board} do
      reader = user_fixture("bh1716-header@example.com")
      share_fixture(board, reader, "read")
      {:ok, view, _} = live(conn_as(reader), ~p"/boards/#{board.id}")

      name = view |> element("#board-name") |> render()
      refute name =~ "chip-line"
      assert name =~ ~r/title="Shared with you \(read only\)\nCode: bh1716f/
    end

    test "the ⋯ menu and the phone's Menu copy the board's code", %{conn: conn, board: board} do
      {:ok, view, _} = live(conn, ~p"/boards/#{board.id}")

      for id <- ["board-share", "board-share-menu"] do
        assert has_element?(
                 view,
                 ~s(##{id}-copy-code[phx-hook=CopyText][data-target="#{id}-code"]),
                 "Copy board code"
               )

        assert has_element?(view, "##{id}-copy-code ##{id}-code", "bh1716f")
      end
    end

    test "a reader gets the copy as well, though not Share", %{board: board} do
      reader = user_fixture("bh1716-copy@example.com")
      share_fixture(board, reader, "read")
      {:ok, view, _} = live(conn_as(reader), ~p"/boards/#{board.id}")

      assert has_element?(view, "#board-share-copy-code", "Copy board code")
      refute has_element?(view, "#board-share")
    end
  end

  describe "the toolbar's Share button" do
    setup %{user: user} do
      %{board: board_fixture(%{"name" => "Keystone", "code" => "bh1716g"}, owner: user)}
    end

    test "is on the board's toolbar and opens settings on Sharing", %{conn: conn, board: board} do
      {:ok, view, _} = live(conn, ~p"/boards/#{board.id}")

      assert has_element?(view, "#board-actions #board-share-button", "Share")
      # The ⋯ entry stays.
      assert has_element?(view, "#board-share", "Share this board")

      view |> element("#board-share-button") |> render_click()
      assert_patch(view, "/boards/#{board.id}/settings?tab=sharing")
      assert has_element?(view, "#settings-tab-sharing[aria-selected=true]")
      refute has_element?(view, "#settings-panel-sharing.hidden")
      assert has_element?(view, "#settings-panel-general.hidden")
    end

    test "is on every view's toolbar, keeping the view's query", %{conn: conn, board: board} do
      {:ok, view, _} = live(conn, ~p"/boards/#{board.id}/table")
      assert has_element?(view, "#board-actions #board-share-button")

      view |> element("#board-share-button") |> render_click()
      {path, query} = view |> assert_patch() |> URI.parse() |> then(&{&1.path, &1.query})
      assert path == "/boards/#{board.id}/table/settings"
      assert URI.decode_query(query)["tab"] == "sharing"
      assert has_element?(view, "#settings-tab-sharing[aria-selected=true]")
    end

    test "is not there for someone who can't share the board", %{board: board} do
      for {level, email} <- [{"read", "bh1716-r@example.com"}, {"write", "bh1716-w@example.com"}] do
        member = user_fixture(email)
        share_fixture(board, member, level)
        {:ok, view, _} = live(conn_as(member), ~p"/boards/#{board.id}")

        refute has_element?(view, "#board-share-button")
        refute has_element?(view, "#board-share")
      end
    end
  end
end
