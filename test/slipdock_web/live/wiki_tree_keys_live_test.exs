defmodule SlipdockWeb.WikiTreeKeysLiveTest do
  @moduledoc """
  What the tree's keyboard asks the server for (W-103 R11.6): F2 renames a
  page, Delete archives one, each after asking; folders use the folder
  dialogs. And the button that shows where you are (R11.7).
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.Wiki

  setup %{user: user} do
    board = board_fixture(%{"name" => "Keys", "code" => "treekeys"}, owner: user)
    page = page_fixture(board, %{"title" => "Retry policy"})
    %{board: board, page: page}
  end

  test "F2 on a page asks for a title and renames it", %{conn: conn, board: board, page: page} do
    {:ok, view, _} = live(conn, ~p"/boards/#{board}/wiki")

    render_hook(view, "rename_page", %{"id" => to_string(page.id)})
    assert has_element?(view, "#tree-rename-form input[value='Retry policy']")

    html = view |> form("#tree-rename-form", %{"title" => "Backoff policy"}) |> render_submit()
    assert html =~ "Renamed to “Backoff policy”"
    assert Wiki.get_page!(page.id).title == "Backoff policy"
    refute has_element?(view, "#tree-prompt")
  end

  test "renaming the page being read follows it to its new address", %{
    conn: conn,
    board: board,
    page: page
  } do
    {:ok, view, _} = live(conn, ~p"/boards/#{board}/wiki/#{page.slug}")
    render_hook(view, "rename_page", %{"id" => page.id})
    view |> form("#tree-rename-form", %{"title" => "Backoff policy"}) |> render_submit()

    renamed = Wiki.get_page!(page.id)
    assert_patch(view, ~p"/boards/#{board}/wiki/#{renamed.slug}")
  end

  test "Delete on a page asks, then archives it", %{conn: conn, board: board, page: page} do
    {:ok, view, _} = live(conn, ~p"/boards/#{board}/wiki/#{page.slug}")

    render_hook(view, "ask_archive_page", %{"id" => to_string(page.id)})
    assert render(view) =~ "Archive “Retry policy”?"

    view |> element("button[phx-click='close_tree_prompt']", "Cancel") |> render_click()
    assert is_nil(Wiki.get_page!(page.id).archived_at)

    render_hook(view, "ask_archive_page", %{"id" => to_string(page.id)})
    view |> element("#tree-archive-confirm") |> render_click()

    refute is_nil(Wiki.get_page!(page.id).archived_at)
    assert_patch(view, ~p"/boards/#{board}/wiki")
  end

  test "a reader, or a page on another board, gets no prompt", %{
    board: board,
    page: page,
    user: owner
  } do
    other = board_fixture(%{"name" => "Other", "code" => "treekeys2"}, owner: owner)
    theirs = page_fixture(other, %{"title" => "Theirs"})
    {:ok, view, _} = live(conn_as(owner), ~p"/boards/#{board}/wiki")

    render_hook(view, "ask_archive_page", %{"id" => to_string(theirs.id)})
    render_hook(view, "rename_page", %{"id" => "junk"})
    refute has_element?(view, "#tree-prompt")

    reader = user_fixture("keys.reader@example.com")
    {:ok, _} = Slipdock.Access.grant(board, reader, "read", owner)
    {:ok, view, _} = live(conn_as(reader), ~p"/boards/#{board}/wiki")
    render_hook(view, "ask_archive_page", %{"id" => to_string(page.id)})
    refute has_element?(view, "#tree-prompt")
    assert render_hook(view, "archive_from_tree", %{}) =~ "couldn&#39;t be archived"
    assert is_nil(Wiki.get_page!(page.id).archived_at)
  end

  test "the show-where-I-am button is there only with something to show", %{
    conn: conn,
    board: board,
    page: page
  } do
    {:ok, view, _} = live(conn, ~p"/boards/#{board}/wiki")
    refute has_element?(view, "#wiki-tree-reveal")

    render_patch(view, ~p"/boards/#{board}/wiki/#{page.slug}")
    assert has_element?(view, "#wiki-tree-reveal[data-tree-reveal]")
  end
end
