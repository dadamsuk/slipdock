defmodule SlipdockWeb.WikiFilePanelLiveTest do
  @moduledoc """
  #768: a wiki file opened from the tree or a page shows in a panel on the
  right of the wiki, the tree and the page staying put, rather than taking
  the whole page. The WikiFileOpen hook sends `open_file`.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.Wiki.Files

  setup %{user: user} do
    board = board_fixture(%{"name" => "Data"}, owner: user)
    %{board: board, page: page_fixture(board, %{"title" => "Home", "body" => "See it."})}
  end

  defp stored(board, name, bytes) do
    path = Path.join(System.tmp_dir!(), "fp-#{System.unique_integer([:positive])}")
    File.write!(path, bytes)
    {:ok, file} = Files.create(board, %{name: name}, path)
    File.rm(path)
    file
  end

  defp open_file(view, id),
    do: view |> element("#wiki-shell") |> render_hook("open_file", %{"id" => to_string(id)})

  test "a file opens beside the page, which stays where it was",
       %{conn: conn, board: board, page: page} do
    file = stored(board, "sales.csv", "region,total\nNorth,3\n")
    {:ok, view, _} = live(conn, ~p"/boards/#{board}/wiki/#{page.slug}")
    refute has_element?(view, "#wiki-file-panel")

    open_file(view, file.id)

    panel = view |> element("#wiki-file-panel") |> render()
    assert panel =~ "sales.csv"
    assert panel =~ "North"
    assert has_element?(view, "#wiki-file-panel #file-table")
    assert has_element?(view, ~s(#wiki-file-download[href="#{Files.url(file)}"]))
    assert has_element?(view, ~s(#wiki-file-full[href="/files/#{file.id}"][data-own-page]))
    # The page and the tree are still there.
    assert view |> element("#wiki-main") |> render() =~ "See it."
    assert has_element?(view, "#wiki-tree")
  end

  test "an HTML file shows in a sandboxed frame in the panel", %{conn: conn, board: board} do
    file = stored(board, "Report.html", "<p>Hi</p>")
    {:ok, view, _} = live(conn, ~p"/boards/#{board}/wiki")
    open_file(view, file.id)

    frame = view |> element("#wiki-file-panel iframe#file-html") |> render()
    assert frame =~ "#{Files.url(file)}?view=inline"
    assert frame =~ ~s(sandbox="")
  end

  test "an .m4a plays in the panel", %{conn: conn, board: board} do
    file = stored(board, "Memo.m4a", "ftyp")
    {:ok, view, _} = live(conn, ~p"/boards/#{board}/wiki")
    open_file(view, file.id)

    player = view |> element("#wiki-file-panel audio#file-audio") |> render()
    assert player =~ "#{Files.url(file)}?view=inline"
    assert player =~ "controls"
  end

  test "another file takes the panel's place", %{conn: conn, board: board} do
    one = stored(board, "one.txt", "first")
    two = stored(board, "two.txt", "second")
    {:ok, view, _} = live(conn, ~p"/boards/#{board}/wiki")

    open_file(view, one.id)
    open_file(view, two.id)

    panel = view |> element("#wiki-file-panel") |> render()
    assert panel =~ "second"
    refute panel =~ "first"
  end

  test "the panel stays open while another page is read", %{conn: conn, board: board, page: page} do
    other = page_fixture(board, %{"title" => "Other", "body" => "Elsewhere."})
    file = stored(board, "notes.txt", "kept")
    {:ok, view, _} = live(conn, ~p"/boards/#{board}/wiki/#{page.slug}")
    open_file(view, file.id)

    render_patch(view, ~p"/boards/#{board}/wiki/#{other.slug}")

    assert view |> element("#wiki-main") |> render() =~ "Elsewhere."
    assert view |> element("#wiki-file-panel") |> render() =~ "kept"
  end

  test "the X and Escape put it away", %{conn: conn, board: board} do
    file = stored(board, "notes.txt", "x")
    {:ok, view, _} = live(conn, ~p"/boards/#{board}/wiki")

    open_file(view, file.id)
    view |> element("#wiki-file-close") |> render_click()
    refute has_element?(view, "#wiki-file-panel")

    open_file(view, file.id)
    view |> element("#wiki-file-panel") |> render_keydown(%{"key" => "Escape"})
    refute has_element?(view, "#wiki-file-panel")
  end

  test "a file on a board the reader can't see, an archived one and a nonsense id are refused",
       %{conn: conn, board: board} do
    stranger = user_fixture("owner-elsewhere@example.com")
    theirs = board_fixture(%{"name" => "Private"}, owner: stranger)
    hidden = stored(theirs, "secret.txt", "classified")
    archived = stored(board, "old.txt", "gone")
    {:ok, _} = Files.archive(archived)

    {:ok, view, _} = live(conn, ~p"/boards/#{board}/wiki")

    for id <- [hidden.id, archived.id, "nope"] do
      html = open_file(view, id)
      assert html =~ "isn&#39;t yours to see"
      refute has_element?(view, "#wiki-file-panel")
    end

    refute render(view) =~ "classified"
  end
end
