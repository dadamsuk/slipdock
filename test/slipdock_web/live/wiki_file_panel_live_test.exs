defmodule SlipdockWeb.WikiFilePanelLiveTest do
  @moduledoc """
  #768, #773: a wiki file opened from the tree or a page shows in the page's
  place beside the tree — two columns, not a third beside the page — and
  putting it away brings the page back. The WikiFileOpen hook sends
  `open_file`.
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

  test "a file opens in the page's place, the tree staying beside it",
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
    # The tree stays; the page is hidden, not thrown away.
    assert has_element?(view, "#wiki-tree")
    assert has_element?(view, "#wiki-main.hidden")
    assert view |> element("#wiki-main") |> render() =~ "See it."
    # It fills the width the page had rather than a slice beside it.
    assert panel =~ "lg:flex-1"
    refute panel =~ "lg:w-["
  end

  test "a .vtt file opened from the tree reads as a transcript in the panel (#774)",
       %{conn: conn, board: board, page: page} do
    file =
      stored(board, "call.vtt", "WEBVTT\n\n00:00:02.000 --> 00:00:04.000\n<v Ada>Hello there.\n")

    {:ok, view, _} = live(conn, ~p"/boards/#{board}/wiki/#{page.slug}")

    open_file(view, file.id)

    turn =
      view |> element(~s(#wiki-file-panel #file-transcript li[data-speaker="Ada"])) |> render()

    assert turn =~ "Hello there."
    assert turn =~ "0:02"
  end

  test "putting the file away brings the page back", %{conn: conn, board: board, page: page} do
    file = stored(board, "notes.txt", "x")
    {:ok, view, _} = live(conn, ~p"/boards/#{board}/wiki/#{page.slug}")
    refute has_element?(view, "#wiki-main.hidden")

    open_file(view, file.id)
    view |> element("#wiki-file-close") |> render_click()

    refute has_element?(view, "#wiki-file-panel")
    refute has_element?(view, "#wiki-main.hidden")
    assert view |> element("#wiki-main") |> render() =~ "See it."
  end

  test "a half-written edit survives a file being looked at", %{
    conn: conn,
    board: board,
    page: page
  } do
    file = stored(board, "notes.txt", "x")
    {:ok, view, _} = live(conn, ~p"/boards/#{board}/wiki/#{page.slug}/edit")
    view |> form("#page-form", page: %{body: "Unsaved words"}) |> render_change()

    open_file(view, file.id)
    assert has_element?(view, "#wiki-main.hidden")
    view |> element("#wiki-file-panel") |> render_keydown(%{"key" => "Escape"})

    assert view |> element("#wiki-main") |> render() =~ "Unsaved words"
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

  test "opening a page from the tree puts the file away and shows the page",
       %{conn: conn, board: board, page: page} do
    other = page_fixture(board, %{"title" => "Other", "body" => "Elsewhere."})
    file = stored(board, "notes.txt", "kept")
    {:ok, view, _} = live(conn, ~p"/boards/#{board}/wiki/#{page.slug}")

    open_file(view, file.id)
    render_patch(view, ~p"/boards/#{board}/wiki/#{other.slug}")
    refute has_element?(view, "#wiki-file-panel")
    refute has_element?(view, "#wiki-main.hidden")
    assert view |> element("#wiki-main") |> render() =~ "Elsewhere."

    # The page that was open is shown again too, not the file left over.
    open_file(view, file.id)
    render_patch(view, ~p"/boards/#{board}/wiki/#{other.slug}")
    refute has_element?(view, "#wiki-file-panel")
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
