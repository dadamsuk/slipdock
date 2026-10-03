defmodule SlipdockWeb.WikiFoldersLiveTest do
  @moduledoc """
  Folders in the browser: making them from the wiki's own sidebar, filing a
  page into one, and the Wiki view over every board at once.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.Wiki

  setup %{user: user} do
    board = board_fixture(%{"name" => "Handbook", "code" => "handbook"}, owner: user)
    %{board: board}
  end

  test "a folder is made from the sidebar and shows in the tree", %{conn: conn, board: board} do
    {:ok, view, _html} = live(conn, ~p"/boards/#{board}/wiki")

    view |> element("button", "New folder") |> render_click()
    assert has_element?(view, "#folder-modal")

    html =
      view
      |> element("#folder-form")
      |> render_submit(%{"name" => "Design decisions", "parent_id" => ""})

    assert html =~ "Design decisions"
    assert {:ok, folder} = Wiki.find_folder(board, "design-decisions")
    assert folder.parent_id == nil
  end

  test "the New folder dialog opens with folders already on the board", %{
    conn: conn,
    board: board
  } do
    # The tree of parents is where a nil-vs-false slip shows up, and only
    # when there is something to list.
    {:ok, parent} = Wiki.create_folder(board, %{"name" => "Design"})

    {:ok, view, _html} = live(conn, ~p"/boards/#{board}/wiki")

    html =
      view |> element("button[phx-click='new_folder']:not([phx-value-parent])") |> render_click()

    assert html =~ "New folder"
    assert has_element?(view, "#folder-parent-picker [data-row][data-id='#{parent.id}']")

    # And renaming one opens the same dialog with it filled in — with itself
    # out of the picker, since a folder cannot be filed in itself.
    view |> element("button[phx-click='rename_folder']") |> render_click()
    assert has_element?(view, "#folder-form input[value='Design']")

    assert has_element?(
             view,
             "#folder-parent-picker [data-row][data-id='#{parent.id}'][disabled]"
           )
  end

  test "a name with slashes makes the path", %{conn: conn, board: board} do
    {:ok, view, _html} = live(conn, ~p"/boards/#{board}/wiki")

    view |> element("button", "New folder") |> render_click()

    view
    |> element("#folder-form")
    |> render_submit(%{"name" => "Design/Decisions", "parent_id" => ""})

    assert {:ok, leaf} = Wiki.find_folder(board, "Design/Decisions")
    assert Wiki.folder_path(leaf) == "Design/Decisions"
  end

  test "a page is filed and unfiled from its own header", %{conn: conn, board: board} do
    {:ok, folder} = Wiki.create_folder(board, %{"name" => "Specs"})
    page = page_fixture(board, %{"title" => "Retry policy", "body" => "…"})

    {:ok, view, html} = live(conn, ~p"/boards/#{board}/wiki/#{page.slug}")
    assert html =~ "Not in a folder"

    html = view |> element("button[phx-value-folder='#{folder.id}']") |> render_click()
    assert html =~ "Filed in"
    assert Wiki.get_page!(page.id).folder_id == folder.id

    view |> element("button[phx-value-folder='none']") |> render_click()
    assert Wiki.get_page!(page.id).folder_id == nil
  end

  test "deleting a folder that holds something asks what to do with it", %{
    conn: conn,
    board: board
  } do
    {:ok, folder} = Wiki.create_folder(board, %{"name" => "Specs"})
    page = page_fixture(board, %{"title" => "Retry policy"})
    {:ok, _} = Wiki.file_page(page, folder)

    {:ok, view, _html} = live(conn, ~p"/boards/#{board}/wiki")

    html = view |> element("button[phx-click='ask_delete_folder']") |> render_click()
    assert html =~ "Delete “Specs”?"
    assert html =~ "1 page"

    html = view |> element("button[phx-value-how='keep']") |> render_click()

    assert html =~ "Nothing in it was deleted"
    assert html =~ "Retry policy"
    assert Wiki.get_page!(page.id).folder_id == nil
  end

  test "an empty folder is deleted without being asked twice", %{conn: conn, board: board} do
    {:ok, folder} = Wiki.create_folder(board, %{"name" => "Specs"})

    {:ok, view, _html} = live(conn, ~p"/boards/#{board}/wiki")

    html = view |> element("button[phx-click='ask_delete_folder']") |> render_click()

    assert html =~ "Nothing in it was deleted"
    refute has_element?(view, "#folder-delete-modal")
    assert Wiki.get_folder(folder.id) == nil
  end

  test "deleting a folder and everything in it takes the pages with it", %{
    conn: conn,
    board: board
  } do
    {:ok, folder} = Wiki.create_folder(board, %{"name" => "Specs"})
    page = page_fixture(board, %{"title" => "Retry policy"})
    {:ok, _} = Wiki.file_page(page, folder)

    {:ok, view, _html} = live(conn, ~p"/boards/#{board}/wiki")

    view |> element("button[phx-click='ask_delete_folder']") |> render_click()
    html = view |> element("button[phx-value-how='purge']") |> render_click()

    assert html =~ "and everything in it"
    refute html =~ "Retry policy"
    assert Wiki.get_page(page.id) == nil
    assert Wiki.get_folder(folder.id) == nil
  end

  describe "searching the tree" do
    test "a folder name is a hit, and brings what is in it", %{conn: conn, board: board} do
      {:ok, specs} = Wiki.create_folder(board, %{"name" => "Specs"})
      {:ok, _other} = Wiki.create_folder(board, %{"name" => "Contracts"})
      filed = page_fixture(board, %{"title" => "Retry policy"})
      {:ok, _} = Wiki.file_page(filed, specs)
      _loose = page_fixture(board, %{"title" => "Launch plan"})

      {:ok, view, _html} = live(conn, ~p"/boards/#{board}/wiki")

      html = view |> form("#wiki-search") |> render_change(%{"q" => "spec"})

      # The folder matched, so it and everything in it stay…
      assert html =~ "Specs"
      assert html =~ "Retry policy"
      # …and the filing with nothing matching in it goes.
      refute html =~ "Contracts"
      refute html =~ "Launch plan"
    end

    test "a page still matches on its own, and empties its folder's siblings", %{
      conn: conn,
      board: board
    } do
      {:ok, specs} = Wiki.create_folder(board, %{"name" => "Specs"})
      {:ok, _empty} = Wiki.create_folder(board, %{"name" => "Contracts"})
      filed = page_fixture(board, %{"title" => "Retry policy"})
      {:ok, _} = Wiki.file_page(filed, specs)

      {:ok, view, _html} = live(conn, ~p"/boards/#{board}/wiki")

      html = view |> form("#wiki-search") |> render_change(%{"q" => "retry"})

      assert html =~ "Retry policy"
      assert html =~ "Specs"
      refute html =~ "Contracts"
    end

    test "the way to full text is one click from the search that missed", %{
      conn: conn,
      board: board
    } do
      page_fixture(board, %{"title" => "Retry policy"})

      {:ok, view, html} = live(conn, ~p"/boards/#{board}/wiki")
      refute html =~ "Full text search for"

      html = view |> form("#wiki-search") |> render_change(%{"q" => "application form"})

      assert html =~ "Full text search for"
      assert html =~ "No page or folder name matches that."

      # The query and this board travel with it, in whatever order the router
      # writes them.
      assert [_, href] = Regex.run(~r{<a[^>]+href="(/search\?[^"]+)"}, html)
      query = href |> String.replace("&amp;", "&") |> URI.parse() |> Map.get(:query)

      assert URI.decode_query(query) == %{
               "q" => "application form",
               "board" => to_string(board.id)
             }
    end
  end

  describe "organising the tree by dragging" do
    setup %{board: board} do
      {:ok, folder} = Wiki.create_folder(board, %{"name" => "Specs"})
      page = page_fixture(board, %{"title" => "Retry policy"})
      %{folder: folder, page: page}
    end

    test "the tree is only draggable in organise mode", %{conn: conn, board: board} do
      {:ok, view, _html} = live(conn, ~p"/boards/#{board}/wiki")

      refute has_element?(view, "#wiki-tree[data-organising='true']")
      refute has_element?(view, "[data-tree-list]")

      view |> element("button[phx-click='toggle_organise']") |> render_click()

      assert has_element?(view, "#wiki-tree[data-organising='true']")
      assert has_element?(view, "[data-tree-list='folders'][data-into='folder:']")
      assert has_element?(view, "[data-tree-list='pages'][data-into='folder:']")
    end

    test "a page dropped in a folder is filed there and parented to nothing", %{
      conn: conn,
      board: board,
      folder: folder,
      page: page
    } do
      {:ok, parent} = Wiki.create_page(board, %{"title" => "Spec"}, [])
      {:ok, page} = Wiki.move_page(page, parent)

      {:ok, view, _html} = live(conn, ~p"/boards/#{board}/wiki")

      render_click(view, "tree_move", %{
        "kind" => "page",
        "id" => to_string(page.id),
        "into" => "folder:#{folder.id}",
        "before" => nil
      })

      moved = Wiki.get_page!(page.id)
      assert moved.folder_id == folder.id
      assert moved.parent_id == nil
    end

    test "a page dropped on a page becomes part of it, filed where it is", %{
      conn: conn,
      board: board,
      folder: folder,
      page: page
    } do
      {:ok, parent} = Wiki.create_page(board, %{"title" => "Spec"}, [])
      {:ok, parent} = Wiki.file_page(parent, folder)

      {:ok, view, _html} = live(conn, ~p"/boards/#{board}/wiki")

      render_click(view, "tree_move", %{
        "kind" => "page",
        "id" => to_string(page.id),
        "into" => "page:#{parent.id}",
        "before" => nil
      })

      moved = Wiki.get_page!(page.id)
      assert moved.parent_id == parent.id
      assert moved.folder_id == folder.id
    end

    test "a page dropped above another lands above it", %{conn: conn, board: board, page: first} do
      second = page_fixture(board, %{"title" => "Rollback"})

      {:ok, view, _html} = live(conn, ~p"/boards/#{board}/wiki")

      render_click(view, "tree_move", %{
        "kind" => "page",
        "id" => to_string(second.id),
        "into" => "folder:",
        "before" => to_string(first.id)
      })

      assert Wiki.get_page!(second.id).position < Wiki.get_page!(first.id).position
    end

    test "a folder dropped in a folder moves under it, and is packed in order", %{
      conn: conn,
      board: board,
      folder: folder
    } do
      {:ok, other} = Wiki.create_folder(board, %{"name" => "Runbooks"})
      {:ok, third} = Wiki.create_folder(board, %{"name" => "Contracts"})

      {:ok, view, _html} = live(conn, ~p"/boards/#{board}/wiki")

      render_click(view, "tree_move", %{
        "kind" => "folder",
        "id" => to_string(other.id),
        "into" => "folder:#{folder.id}",
        "before" => nil
      })

      assert Wiki.get_folder(other.id).parent_id == folder.id

      # And dropping one above another orders them.
      render_click(view, "tree_move", %{
        "kind" => "folder",
        "id" => to_string(third.id),
        "into" => "folder:",
        "before" => to_string(folder.id)
      })

      assert Wiki.get_folder(third.id).position < Wiki.get_folder(folder.id).position
    end

    test "a folder cannot be dropped inside itself", %{conn: conn, board: board, folder: folder} do
      {:ok, inner} = Wiki.create_folder(board, %{"name" => "Specs/Drafts"})

      {:ok, view, _html} = live(conn, ~p"/boards/#{board}/wiki")

      html =
        render_click(view, "tree_move", %{
          "kind" => "folder",
          "id" => to_string(folder.id),
          "into" => "folder:#{inner.id}",
          "before" => nil
        })

      assert html =~ "cannot be moved inside itself"
      assert Wiki.get_folder(folder.id).parent_id == nil
    end

    test "a reader cannot drag anything", %{board: board, folder: folder, page: page, user: owner} do
      reader = user_fixture("reader@example.com")
      {:ok, _} = Slipdock.Access.grant(board, reader, "read", owner)

      conn = log_in_user(build_conn(), reader)
      {:ok, view, _html} = live(conn, ~p"/boards/#{board}/wiki")

      refute has_element?(view, "button[phx-click='toggle_organise']")

      render_click(view, "tree_move", %{
        "kind" => "page",
        "id" => to_string(page.id),
        "into" => "folder:#{folder.id}",
        "before" => nil
      })

      assert Wiki.get_page!(page.id).folder_id == nil
    end
  end

  describe "a folder, looked at" do
    test "it lists what is filed in it, and what is below it", %{conn: conn, board: board} do
      {:ok, folder} = Wiki.create_folder(board, %{"name" => "Specs"})
      {:ok, _sub} = Wiki.create_folder(board, %{"name" => "Specs/Drafts"})
      page = page_fixture(board, %{"title" => "Retry policy"})
      {:ok, _} = Wiki.file_page(page, folder)
      _elsewhere = page_fixture(board, %{"title" => "Launch plan"})

      {:ok, view, html} = live(conn, ~p"/boards/#{board}/wiki?folder=#{folder.id}")

      assert html =~ "Specs"
      assert html =~ "Drafts"
      assert has_element?(view, "a[href='/boards/#{board.id}/wiki/#{page.slug}']")
      # The one filed elsewhere is in the sidebar, not in the folder's list.
      refute has_element?(view, "section a", "Launch plan")
    end

    test "an empty folder says so and offers the first page", %{conn: conn, board: board} do
      {:ok, folder} = Wiki.create_folder(board, %{"name" => "Specs"})

      {:ok, view, html} = live(conn, ~p"/boards/#{board}/wiki?folder=#{folder.id}")

      assert html =~ "Nothing filed here"
      assert has_element?(view, "a[href='/boards/#{board.id}/wiki/new?folder=#{folder.id}']")
    end

    test "a folder that isn't there falls back to the whole wiki", %{conn: conn, board: board} do
      {:ok, _view, html} = live(conn, ~p"/boards/#{board}/wiki?folder=nonesuch")

      assert html =~ "#{board.name} wiki"
    end
  end

  test "a new page started in a folder is filed there", %{conn: conn, board: board} do
    {:ok, folder} = Wiki.create_folder(board, %{"name" => "Specs"})

    {:ok, view, _html} = live(conn, ~p"/boards/#{board}/wiki/new?folder=#{folder.id}")

    assert {:error, {:live_redirect, %{to: _}}} =
             view
             |> form("#page-form", page: %{title: "Rollback", folder_id: to_string(folder.id)})
             |> render_submit()

    assert {:ok, page} = Wiki.find_page(board, "rollback")
    assert page.folder_id == folder.id
  end

  describe "the Wiki view over every board" do
    test "boards are the top level, with their folders and pages inside", %{
      conn: conn,
      board: board,
      user: user
    } do
      other = board_fixture(%{"name" => "Marketing", "code" => "mkt"}, owner: user)
      {:ok, folder} = Wiki.create_folder(board, %{"name" => "Specs"})
      filed = page_fixture(board, %{"title" => "Retry policy"})
      {:ok, _} = Wiki.file_page(filed, folder)
      _loose = page_fixture(other, %{"title" => "Launch plan"})

      {:ok, view, html} = live(conn, ~p"/wiki")

      assert html =~ "Handbook"
      assert html =~ "Marketing"
      assert html =~ "Specs"
      assert html =~ "Retry policy"
      assert html =~ "Launch plan"
      assert has_element?(view, "a[href='/boards/#{board.id}/wiki/#{filed.slug}']")
    end

    test "searching narrows to the pages that match", %{conn: conn, board: board} do
      page_fixture(board, %{"title" => "Retry policy"})
      page_fixture(board, %{"title" => "Launch plan"})

      {:ok, view, _html} = live(conn, ~p"/wiki")

      html = view |> form("#wiki-all-search") |> render_change(%{"q" => "retry"})

      assert html =~ "Retry policy"
      refute html =~ "Launch plan"
    end

    test "a search hides the folders with nothing matching in them", %{
      conn: conn,
      board: board
    } do
      {:ok, holds} = Wiki.create_folder(board, %{"name" => "Runbooks"})
      {:ok, empty} = Wiki.create_folder(board, %{"name" => "Contracts"})
      page = page_fixture(board, %{"title" => "Retry policy"})
      {:ok, _} = Wiki.file_page(page, holds)

      {:ok, view, html} = live(conn, ~p"/wiki")
      assert html =~ empty.name

      html = view |> form("#wiki-all-search") |> render_change(%{"q" => "retry"})

      assert html =~ "Runbooks"
      refute html =~ "Contracts"
    end

    test "a board the reader cannot see is not listed", %{conn: conn} do
      stranger = user_fixture("stranger@example.com")
      hidden = board_fixture(%{"name" => "Secret plans", "code" => "secret"}, owner: stranger)
      page_fixture(hidden, %{"title" => "The plan"})

      {:ok, _view, html} = live(conn, ~p"/wiki")

      refute html =~ "Secret plans"
      refute html =~ "The plan"
    end
  end
end
