defmodule SlipdockWeb.WikiIconsLiveTest do
  @moduledoc """
  Icons and colours on wiki folders and pages in the browser (#792): chosen
  in the folder dialog and the page editor, shown on the wiki's main page,
  and in the tree while the board's switch for it is on.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures
  import SlipdockWeb.WikiTreeHelpers

  alias Slipdock.Wiki

  setup %{user: user} do
    board = board_fixture(%{"name" => "Dressed", "code" => "dressed792"}, owner: user)
    %{board: board}
  end

  test "a new folder is given an icon and a colour in its dialog", %{conn: conn, board: board} do
    {:ok, view, _html} = live(conn, ~p"/boards/#{board}/wiki")

    view |> element("button", "New folder") |> render_click()
    assert has_element?(view, "#folder-dress input[name='icon'][value='star']")
    assert has_element?(view, "#folder-dress input[name='color'][value='amber']")

    view
    |> element("#folder-form")
    |> render_submit(%{
      "name" => "Favourites",
      "parent_id" => "",
      "icon" => "star",
      "color" => "amber"
    })

    assert {:ok, %{icon: "star", color: "amber"}} = Wiki.find_folder(board, "favourites")
  end

  test "editing a folder shows what it wears, and None takes it off", %{conn: conn, board: board} do
    {:ok, folder} =
      Wiki.create_folder(board, %{"name" => "Ops", "icon" => "key", "color" => "red"})

    {:ok, view, _html} = live(conn, ~p"/boards/#{board}/wiki?folder=#{folder.id}")

    view |> element("button[phx-click='rename_folder']") |> render_click()
    assert has_element?(view, "#folder-dress input[name='icon'][value='key'][checked]")
    assert has_element?(view, "#folder-dress input[name='color'][value='red'][checked]")

    view
    |> element("#folder-form")
    |> render_submit(%{"name" => "Ops", "parent_id" => "", "icon" => "", "color" => ""})

    assert %{icon: nil, color: nil} = Wiki.get_folder(folder.id)
  end

  test "a rename that sends no dress leaves it alone", %{conn: conn, board: board} do
    {:ok, folder} =
      Wiki.create_folder(board, %{"name" => "Ops", "icon" => "key", "color" => "red"})

    {:ok, view, _html} = live(conn, ~p"/boards/#{board}/wiki?folder=#{folder.id}")

    view |> element("button[phx-click='rename_folder']") |> render_click()
    render_hook(view, "save_folder", %{"name" => "Operations", "parent_id" => ""})

    assert %{name: "Operations", icon: "key", color: "red"} = Wiki.get_folder(folder.id)
  end

  test "the page editor sets a page's icon and colour", %{conn: conn, board: board} do
    page = page_fixture(board, %{"title" => "Launch"})
    {:ok, view, _html} = live(conn, ~p"/boards/#{board}/wiki/#{page.slug}/edit")

    assert has_element?(view, "#page-dress input[name='page[icon]'][value='rocket-launch']")

    view
    |> form("#page-form",
      page: %{title: "Launch", body: "", icon: "rocket-launch", color: "rose"}
    )
    |> render_submit()

    assert %{icon: "rocket-launch", color: "rose"} = Wiki.get_page!(page.id)
  end

  # #1203: each pick goes to the server as the form's change, and the render
  # that came back had dropped both names, so a colour unpicked the icon.
  test "the editor keeps an icon picked while a colour is picked, and the other way round", %{
    conn: conn,
    board: board
  } do
    page = page_fixture(board, %{"title" => "Launch"})
    {:ok, view, _html} = live(conn, ~p"/boards/#{board}/wiki/#{page.slug}/edit")

    view |> form("#page-form", page: %{icon: "briefcase"}) |> render_change()
    assert has_element?(view, "#page-dress input[name='page[icon]'][value='briefcase'][checked]")
    refute has_element?(view, "#page-dress input[name='page[icon]'][value=''][checked]")

    view |> form("#page-form", page: %{icon: "briefcase", color: "amber"}) |> render_change()
    assert has_element?(view, "#page-dress input[name='page[icon]'][value='briefcase'][checked]")
    assert has_element?(view, "#page-dress input[name='page[color]'][value='amber'][checked]")
    # The icons wear the colour picked, before anything is saved.
    assert has_element?(view, "#page-dress span.hero-briefcase.text-amber-500")

    view |> form("#page-form", page: %{icon: "star", color: "amber"}) |> render_change()
    assert has_element?(view, "#page-dress input[name='page[icon]'][value='star'][checked]")
    assert has_element?(view, "#page-dress input[name='page[color]'][value='amber'][checked]")

    # None for each goes back to the plain radios.
    view |> form("#page-form", page: %{icon: "", color: ""}) |> render_change()
    assert has_element?(view, "#page-dress input[name='page[icon]'][value=''][checked]")
    assert has_element?(view, "#page-dress input[name='page[color]'][value=''][checked]")
    refute has_element?(view, "#page-dress input[name='page[icon]'][value='star'][checked]")
  end

  test "the editor opens on what a page already wears", %{conn: conn, board: board} do
    page = page_fixture(board, %{"title" => "Worn", "icon" => "key", "color" => "red"})
    {:ok, view, _html} = live(conn, ~p"/boards/#{board}/wiki/#{page.slug}/edit")

    assert has_element?(view, "#page-dress input[name='page[icon]'][value='key'][checked]")
    assert has_element?(view, "#page-dress input[name='page[color]'][value='red'][checked]")
  end

  test "the main page shows them: folder cards, a folder's listing and a page's heading", %{
    conn: conn,
    board: board
  } do
    {:ok, folder} =
      Wiki.create_folder(board, %{"name" => "Ideas", "icon" => "light-bulb", "color" => "amber"})

    {:ok, _inner} =
      Wiki.create_folder(board, %{"name" => "Wild", "parent_id" => folder.id, "icon" => "fire"})

    page =
      page_fixture(board, %{
        "title" => "Moonshot",
        "folder_id" => folder.id,
        "icon" => "rocket-launch",
        "color" => "violet"
      })

    plain = page_fixture(board, %{"title" => "Plain one", "folder_id" => folder.id})

    {:ok, index, _html} = live(conn, ~p"/boards/#{board}/wiki")
    assert has_element?(index, "span.hero-light-bulb.text-amber-500[data-icon='light-bulb']")
    assert has_element?(index, "span.hero-fire[data-icon='fire']")

    assert has_element?(
             index,
             "a[href$='/wiki/#{page.slug}'] span.hero-rocket-launch.text-violet-500"
           )

    # A page that wears nothing has no icon on the main page, as before.
    refute has_element?(index, "a[href$='/wiki/#{plain.slug}'] span[data-icon]")
    refute has_element?(index, "a[href$='/wiki/#{plain.slug}'] span.hero-document-text")

    {:ok, listing, _html} = live(conn, ~p"/boards/#{board}/wiki?folder=#{folder.id}")
    assert has_element?(listing, "h1 span.hero-light-bulb.text-amber-500")
    assert has_element?(listing, "a span.hero-fire[data-icon='fire']")
    assert has_element?(listing, "a[href$='/wiki/#{page.slug}'] span.hero-rocket-launch")

    {:ok, shown, _html} = live(conn, ~p"/boards/#{board}/wiki/#{page.slug}")
    assert has_element?(shown, "h1 span.hero-rocket-launch.text-violet-500")

    {:ok, bare, _html} = live(conn, ~p"/boards/#{board}/wiki/#{plain.slug}")
    refute has_element?(bare, "h1 span[data-icon]")
  end

  test "a folder with no icon of its own wears the plain one, in its colour", %{
    conn: conn,
    board: board
  } do
    {:ok, _} = Wiki.create_folder(board, %{"name" => "Tinted", "color" => "teal"})
    {:ok, view, _html} = live(conn, ~p"/boards/#{board}/wiki")
    assert has_element?(view, "span.hero-folder.text-teal-500[data-color='teal']")
  end

  describe "the tree" do
    setup %{board: board} do
      {:ok, folder} =
        Wiki.create_folder(board, %{"name" => "Ideas", "icon" => "light-bulb", "color" => "amber"})

      page_fixture(board, %{"title" => "Moonshot", "icon" => "rocket-launch", "color" => "violet"})

      page_fixture(board, %{"title" => "Plain one"})
      %{folder: folder}
    end

    test "draws each row's own icon and colour as classes", %{conn: conn, board: board} do
      {:ok, view, _html} = live(conn, ~p"/boards/#{board}/wiki")
      reply = tree_load(view)

      assert %{icon: "hero-light-bulb", tint: "text-amber-500" <> _} = row(reply, "root", "Ideas")

      assert %{icon: "hero-rocket-launch", tint: "text-violet-500" <> _} =
               row(reply, "root", "Moonshot")

      plain = row(reply, "root", "Plain one")
      refute Map.has_key?(plain, :icon)
      refute Map.has_key?(plain, :tint)
    end

    test "a writer turns them off for the board, and on again", %{conn: conn, board: board} do
      {:ok, view, _html} = live(conn, ~p"/boards/#{board}/wiki")
      assert has_element?(view, "#toggle-tree-icons[checked]")

      view |> element("#toggle-tree-icons") |> render_click()
      refute Wiki.tree_icons?(board.id)
      refute has_element?(view, "#toggle-tree-icons[checked]")

      reply = tree_load(view)
      refute Map.has_key?(row(reply, "root", "Ideas"), :icon)
      refute Map.has_key?(row(reply, "root", "Moonshot"), :tint)

      # The main page shows them either way.
      assert has_element?(view, "span.hero-light-bulb[data-icon='light-bulb']")

      view |> element("#toggle-tree-icons") |> render_click()
      assert Wiki.tree_icons?(board.id)
      assert %{icon: "hero-light-bulb"} = row(tree_load(view), "root", "Ideas")
    end

    test "a reader sees the board's choice but cannot change it", %{board: board, user: owner} do
      reader = user_fixture("dress.reader@example.com")
      {:ok, _} = Slipdock.Access.grant(board, reader, "read", owner)
      {:ok, _} = Wiki.set_tree_icons(board, false)

      conn = log_in_user(build_conn(), reader)
      {:ok, view, _html} = live(conn, ~p"/boards/#{board}/wiki")

      refute has_element?(view, "#toggle-tree-icons")
      render_hook(view, "toggle_tree_icons", %{})
      refute Wiki.tree_icons?(board.id)
      refute Map.has_key?(row(tree_load(view), "root", "Ideas"), :icon)
    end

    test "another writer's switch reaches an open tree on its next reload", %{
      conn: conn,
      board: board
    } do
      {:ok, view, _html} = live(conn, ~p"/boards/#{board}/wiki")
      {:ok, _} = Wiki.set_tree_icons(board, false)

      send(view.pid, :reload_wiki)
      _ = render(view)

      refute has_element?(view, "#toggle-tree-icons[checked]")
      refute Map.has_key?(row(tree_load(view), "root", "Ideas"), :icon)
    end
  end
end
