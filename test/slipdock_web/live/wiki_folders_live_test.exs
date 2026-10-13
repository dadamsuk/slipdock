defmodule SlipdockWeb.WikiFoldersLiveTest do
  @moduledoc """
  Folders in the browser: making them from the wiki's own sidebar, filing a
  page into one, and the Wiki view over every board at once.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures
  import SlipdockWeb.WikiTreeHelpers

  alias Slipdock.Wiki

  setup %{user: user} do
    board = board_fixture(%{"name" => "Handbook", "code" => "handbook"}, owner: user)
    %{board: board}
  end

  test "a folder is made from the sidebar and shows in the tree", %{conn: conn, board: board} do
    {:ok, view, _html} = live(conn, ~p"/boards/#{board}/wiki")

    view |> element("button", "New folder") |> render_click()
    assert has_element?(view, "#folder-modal")

    view
    |> element("#folder-form")
    |> render_submit(%{"name" => "Design decisions", "parent_id" => ""})

    assert {:ok, folder} = Wiki.find_folder(board, "design-decisions")
    assert folder.parent_id == nil
    assert %{key: key} = row(tree_load(view), "root", "Design decisions")
    assert key == "folder:#{folder.id}"
  end

  test "the New folder dialog opens with folders already on the board", %{
    conn: conn,
    board: board
  } do
    # The tree of parents is where a nil-vs-false slip shows up, and only
    # when there is something to list.
    {:ok, parent} = Wiki.create_folder(board, %{"name" => "Design"})

    # The folder's own page carries its actions; the tree's menu (drawn by
    # the hook) sends the same events.
    {:ok, view, _html} = live(conn, ~p"/boards/#{board}/wiki?folder=#{parent.id}")

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

    {:ok, view, _html} = live(conn, ~p"/boards/#{board}/wiki?folder=#{folder.id}")

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

    {:ok, view, _html} = live(conn, ~p"/boards/#{board}/wiki?folder=#{folder.id}")

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

    {:ok, view, _html} = live(conn, ~p"/boards/#{board}/wiki?folder=#{folder.id}")

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

      view |> form("#wiki-search") |> render_change(%{"q" => "spec"})
      reply = tree_load(view)

      # The folder matched, so it and everything in it stay, open…
      assert reply.filtering
      assert titles(reply, "root") == ["Specs"]
      assert titles(reply, "folder:#{specs.id}") == ["Retry policy"]
      # …and the filing with nothing matching in it goes.
      assert all_titles(reply) == ["Retry policy", "Specs"]
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

      view |> form("#wiki-search") |> render_change(%{"q" => "retry"})
      reply = tree_load(view)

      assert titles(reply, "root") == ["Specs"]
      assert titles(reply, "folder:#{specs.id}") == ["Retry policy"]
      refute "Contracts" in all_titles(reply)
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

      view |> element("button[phx-click='toggle_organise']") |> render_click()

      # The hook puts a handle on each row when it reads this.
      assert has_element?(view, "#wiki-tree[data-organising='true']")
      assert render(view) =~ "Rest on a shut folder to open it"

      view |> element("button[phx-click='toggle_organise']") |> render_click()
      refute has_element?(view, "#wiki-tree[data-organising='true']")
    end

    test "a drop is followed by the tree being asked for again", %{
      conn: conn,
      board: board,
      folder: folder,
      page: page
    } do
      {:ok, view, _html} = live(conn, ~p"/boards/#{board}/wiki")
      version = view |> element("#wiki-tree") |> render() |> version_of()

      render_click(view, "tree_move", %{
        "kind" => "page",
        "id" => to_string(page.id),
        "into" => "folder:#{folder.id}",
        "before" => nil
      })

      assert view |> element("#wiki-tree") |> render() |> version_of() > version

      assert titles(tree_load(view, %{"keys" => ["folder:#{folder.id}"]}), "folder:#{folder.id}") ==
               ["Retry policy"]
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

  describe "opening and shutting the tree" do
    setup %{board: board} do
      {:ok, specs} = Wiki.create_folder(board, %{"name" => "Specs"})
      {:ok, drafts} = Wiki.create_folder(board, %{"name" => "Specs/Drafts"})
      {:ok, empty} = Wiki.create_folder(board, %{"name" => "Contracts"})
      retry = page_fixture(board, %{"title" => "Retry policy"})
      {:ok, _} = Wiki.file_page(retry, specs)
      sketch = page_fixture(board, %{"title" => "Sketch"})
      {:ok, _} = Wiki.file_page(sketch, drafts)
      %{specs: specs, drafts: drafts, empty: empty, retry: retry, sketch: sketch}
    end

    test "only the root and what the browser has open are sent", %{
      conn: conn,
      board: board,
      specs: specs,
      drafts: drafts
    } do
      {:ok, view, _html} = live(conn, ~p"/boards/#{board}/wiki")

      reply = tree_load(view)
      assert reply.root == "root"
      assert Map.keys(reply.nodes) == ["root"]
      assert titles(reply, "root") == ["Specs", "Contracts"]
      # Small enough that a first visit opens everything, as it always did.
      assert reply.small

      reply = tree_load(view, %{"keys" => ["folder:#{specs.id}"]})
      assert titles(reply, "folder:#{specs.id}") == ["Drafts", "Retry policy"]
      refute Map.has_key?(reply.nodes, "folder:#{drafts.id}")
    end

    test "what a reader has open is kept on the server and comes back", %{
      conn: conn,
      board: board,
      specs: specs,
      drafts: drafts
    } do
      {:ok, view, _html} = live(conn, ~p"/boards/#{board}/wiki")

      # Nothing kept yet: the hook is told so, and opens a small wiki whole.
      reply = SlipdockWeb.WikiTreeHelpers.tree_load_kept(view)
      assert reply.open == nil

      render_hook(view, "tree_open", %{"scope" => "board", "keys" => ["folder:#{specs.id}"]})

      {:ok, view, _html} = live(conn, ~p"/boards/#{board}/wiki")
      reply = SlipdockWeb.WikiTreeHelpers.tree_load_kept(view)
      assert reply.open == ["folder:#{specs.id}"]
      assert titles(reply, "folder:#{specs.id}") == ["Drafts", "Retry policy"]
      refute Map.has_key?(reply.nodes, "folder:#{drafts.id}")

      # A garbled one changes nothing.
      render_hook(view, "tree_open", %{"keys" => "folder:1"})
      assert SlipdockWeb.WikiTreeHelpers.tree_load_kept(view).open == ["folder:#{specs.id}"]
    end

    test "all opens every folder, and only loads just the keys asked for", %{
      conn: conn,
      board: board,
      specs: specs,
      drafts: drafts,
      empty: empty
    } do
      {:ok, view, _html} = live(conn, ~p"/boards/#{board}/wiki")

      reply = tree_load(view, %{"all" => true})

      assert Enum.sort(Map.keys(reply.nodes)) ==
               Enum.sort([
                 "root",
                 "folder:#{specs.id}",
                 "folder:#{drafts.id}",
                 "folder:#{empty.id}"
               ])

      assert titles(reply, "folder:#{drafts.id}") == ["Sketch"]

      reply = tree_load(view, %{"keys" => ["folder:#{drafts.id}"], "only" => true})
      assert Map.keys(reply.nodes) == ["folder:#{drafts.id}"]
    end

    test "an empty folder says it has nothing under it, so no chevron is drawn", %{
      conn: conn,
      board: board
    } do
      {:ok, view, _html} = live(conn, ~p"/boards/#{board}/wiki")

      assert %{count: 0, pages: 0} = row(tree_load(view), "root", "Contracts")
      assert %{count: 2, pages: 2} = row(tree_load(view), "root", "Specs")
    end

    test "keys that are garbage, gone or another board's are left out", %{
      conn: conn,
      board: board,
      user: user
    } do
      other = board_fixture(%{"name" => "Other", "code" => "otherfold"}, owner: user)
      {:ok, theirs} = Wiki.create_folder(other, %{"name" => "Theirs"})
      {:ok, view, _html} = live(conn, ~p"/boards/#{board}/wiki")

      reply =
        tree_load(view, %{"keys" => ["junk", "folder:999999", "folder:#{theirs.id}", 7, nil]})

      assert Map.keys(reply.nodes) == ["root"]
    end

    test "the toggle is hidden with no folders, while filtering and while organising", %{
      conn: conn,
      board: board,
      user: user
    } do
      {:ok, view, _html} = live(conn, ~p"/boards/#{board}/wiki")
      refute has_element?(view, "#wiki-tree-toggle-all-box.hidden")

      view |> form("#wiki-search") |> render_change(%{"q" => "retry"})
      assert has_element?(view, "#wiki-tree-toggle-all-box.hidden")

      view |> form("#wiki-search") |> render_change(%{"q" => ""})
      view |> element("button[phx-click='toggle_organise']") |> render_click()
      assert has_element?(view, "#wiki-tree-toggle-all-box.hidden")

      bare = board_fixture(%{"name" => "Bare", "code" => "bare"}, owner: user)
      {:ok, view, _html} = live(conn, ~p"/boards/#{bare}/wiki")
      assert has_element?(view, "#wiki-tree-toggle-all-box.hidden")
    end

    test "the folders leading to the page being read are loaded and revealed", %{
      conn: conn,
      board: board,
      specs: specs,
      drafts: drafts,
      sketch: sketch
    } do
      {:ok, view, _html} = live(conn, ~p"/boards/#{board}/wiki/#{sketch.slug}")

      reply = tree_load(view)
      assert reply.reveal == ["folder:#{specs.id}", "folder:#{drafts.id}"]
      assert titles(reply, "folder:#{drafts.id}") == ["Sketch"]
      assert has_element?(view, "#wiki-tree[data-current='page:#{sketch.id}']")
    end

    test "a page opened in place says the way to it, for the hook to open", %{
      conn: conn,
      board: board,
      specs: specs,
      drafts: drafts,
      sketch: sketch
    } do
      {:ok, view, _html} = live(conn, ~p"/boards/#{board}/wiki")
      assert has_element?(view, "#wiki-tree[data-current='']")

      render_patch(view, ~p"/boards/#{board}/wiki/#{sketch.slug}")

      reveal = Jason.encode!(["folder:#{specs.id}", "folder:#{drafts.id}"])
      assert has_element?(view, "#wiki-tree[data-current='page:#{sketch.id}']")
      assert has_element?(view, ~s|#wiki-tree[data-reveal='#{reveal}']|)
    end

    test "the folder being looked at, and those above it, are revealed", %{
      conn: conn,
      board: board,
      specs: specs,
      drafts: drafts
    } do
      {:ok, view, _html} = live(conn, ~p"/boards/#{board}/wiki?folder=#{drafts.id}")

      assert tree_load(view).reveal == ["folder:#{specs.id}", "folder:#{drafts.id}"]
      assert has_element?(view, "#wiki-tree[data-current='folder:#{drafts.id}']")
    end

    test "rows link where they go, and drafts, templates and counts ride along", %{
      conn: conn,
      board: board,
      specs: specs
    } do
      page_fixture(board, %{"title" => "Half", "status" => "draft"})
      {:ok, view, _html} = live(conn, ~p"/boards/#{board}/wiki")
      reply = tree_load(view, %{"keys" => ["folder:#{specs.id}"]})

      assert %{href: href, nav: "patch", key: key} = row(reply, "root", "Specs")
      assert href == "/boards/#{board.id}/wiki?folder=#{specs.id}"
      assert key == "folder:#{specs.id}"
      assert %{draft: true, href: "/boards/" <> _} = row(reply, "root", "Half")
      refute Map.has_key?(row(reply, "folder:#{specs.id}", "Retry policy"), :draft)
    end

    test "the page being read is in its folder's rows, however far down", %{
      conn: conn,
      board: board,
      specs: specs
    } do
      notes = for n <- 1..3, do: page_fixture(board, %{"title" => "Note #{n}"})
      Enum.each(notes, &Wiki.file_page(&1, specs))
      last = List.last(notes)
      {:ok, view, _html} = live(conn, ~p"/boards/#{board}/wiki/#{last.slug}")

      # The hook's own ask, when it reveals a page its folder has not
      # reached yet.
      reply =
        tree_load(view, %{
          "keys" => ["folder:#{specs.id}"],
          "only" => true,
          "through" => "page:#{last.id}"
        })

      assert "Note 3" in titles(reply, "folder:#{specs.id}")
    end

    test "a big folder comes a page of rows at a time", %{conn: conn, board: board, specs: specs} do
      for n <- 1..3, do: Wiki.file_page(page_fixture(board, %{"title" => "Note #{n}"}), specs)
      {:ok, view, _html} = live(conn, ~p"/boards/#{board}/wiki")

      render_hook(view, "tree_children", %{"key" => "folder:#{specs.id}", "offset" => 2})
      assert_reply(view, %{key: key, rows: rows})
      assert key == "folder:#{specs.id}"
      # Past the first two pages (Drafts is a folder, not a page): no folders
      # again, and the rest of the pages in their order.
      assert Enum.map(rows, & &1.title) == ["Note 3", "Retry policy"]
    end
  end

  defp version_of(html) do
    [_, v] = Regex.run(~r/data-version="(\d+)"/, html)
    String.to_integer(v)
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

    view
    |> form("#page-form", page: %{title: "Rollback", folder_id: to_string(folder.id)})
    |> render_submit()

    assert_patch(view, ~p"/boards/#{board}/wiki/rollback")

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
