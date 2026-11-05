defmodule SlipdockWeb.WikiHistoryPreviewLiveTest do
  @moduledoc """
  A history row opens onto the lines that version changed (#1745), worked
  out from `Wiki.diff/2` against the version before it. In Chromium:
  `tools/e2e/wiki-history.sh`.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.Wiki

  setup %{user: user} do
    board = board_fixture(%{"name" => "History HP"}, owner: user)
    apart = [user: user, new_revision: true]

    first = %{"title" => "Plan", "body" => "Intro.\n\nShip on Friday.\n\nOld note.\n"}
    page = page_fixture(board, first, user: user)

    # An added paragraph, then a removed one, then a changed one.
    {:ok, page} =
      Wiki.update_page(
        page,
        %{"body" => "Intro.\n\nAdded paragraph.\n\nShip on Friday.\n\nOld note.\n"},
        apart
      )

    {:ok, page} =
      Wiki.update_page(
        page,
        %{"body" => "Intro.\n\nAdded paragraph.\n\nShip on Friday.\n"},
        apart
      )

    {:ok, page} =
      Wiki.update_page(
        page,
        %{"body" => "Intro.\n\nAdded paragraph.\n\nShip on Monday.\n"},
        apart
      )

    [changed, removed, added, first] = Wiki.list_revisions(page)

    %{
      board: board,
      page: page,
      revs: %{changed: changed, removed: removed, added: added, first: first}
    }
  end

  defp history(conn, board, page) do
    {:ok, view, _} = live(conn, ~p"/boards/#{board}/wiki/#{page.slug}/history")
    view
  end

  defp open(view, rev),
    do: view |> element("#revision-preview-toggle-#{rev.id}") |> render_click()

  defp lines(view, rev) do
    view
    |> element("#revision-preview-#{rev.id}")
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("li[data-op]")
    |> Enum.map(fn li ->
      {LazyHTML.attribute(li, "data-op") |> List.first(),
       li |> LazyHTML.query("span.min-w-0") |> LazyHTML.text()}
    end)
  end

  test "every row starts closed, with a button to open it", %{conn: conn} = ctx do
    view = history(conn, ctx.board, ctx.page)

    for {_, rev} <- ctx.revs do
      assert has_element?(
               view,
               "#revision-preview-toggle-#{rev.id}[aria-expanded=false][aria-controls='revision-preview-#{rev.id}']"
             )

      refute has_element?(view, "#revision-preview-#{rev.id}")
    end
  end

  test "an added paragraph shows as its added line", %{conn: conn} = ctx do
    view = history(conn, ctx.board, ctx.page)
    open(view, ctx.revs.added)

    assert has_element?(view, "#revision-preview-toggle-#{ctx.revs.added.id}[aria-expanded=true]")
    assert lines(view, ctx.revs.added) == [{"ins", "Added paragraph."}]
  end

  test "a removed paragraph shows as its removed line", %{conn: conn} = ctx do
    view = history(conn, ctx.board, ctx.page)
    open(view, ctx.revs.removed)
    assert lines(view, ctx.revs.removed) == [{"del", "Old note."}]
  end

  test "a changed paragraph shows the old line removed and the new added", %{conn: conn} = ctx do
    view = history(conn, ctx.board, ctx.page)
    open(view, ctx.revs.changed)

    assert lines(view, ctx.revs.changed) == [
             {"del", "Ship on Friday."},
             {"ins", "Ship on Monday."}
           ]

    assert has_element?(view, "#revision-preview-#{ctx.revs.changed.id} .sr-only", "Removed:")
    assert has_element?(view, "#revision-preview-#{ctx.revs.changed.id} .sr-only", "Added:")
  end

  test "the first version is all added", %{conn: conn} = ctx do
    view = history(conn, ctx.board, ctx.page)
    open(view, ctx.revs.first)

    assert lines(view, ctx.revs.first) ==
             [{"ins", "Intro."}, {"ins", "Ship on Friday."}, {"ins", "Old note."}]
  end

  test "rows open side by side, and a second press closes one", %{conn: conn} = ctx do
    view = history(conn, ctx.board, ctx.page)
    open(view, ctx.revs.added)
    open(view, ctx.revs.changed)
    assert has_element?(view, "#revision-preview-#{ctx.revs.added.id}")
    assert has_element?(view, "#revision-preview-#{ctx.revs.changed.id}")

    open(view, ctx.revs.added)
    refute has_element?(view, "#revision-preview-#{ctx.revs.added.id}")

    assert has_element?(
             view,
             "#revision-preview-toggle-#{ctx.revs.added.id}[aria-expanded=false]"
           )

    assert has_element?(view, "#revision-preview-#{ctx.revs.changed.id}")
  end

  test "a long change shows the first lines and links the version for the rest",
       %{conn: conn, board: board, user: user} do
    page = page_fixture(board, %{"title" => "Long", "body" => "start"}, user: user)
    body = Enum.map_join(1..20, "\n", &"Line #{&1}")
    {:ok, page} = Wiki.update_page(page, %{"body" => body}, user: user, new_revision: true)
    [rev | _] = Wiki.list_revisions(page)

    view = history(conn, board, page)
    open(view, rev)

    assert length(lines(view, rev)) == 12
    assert has_element?(view, "#revision-preview-#{rev.id}", "and 9 more lines")

    assert has_element?(
             view,
             "#revision-preview-#{rev.id} a[href='/boards/#{board.id}/wiki/#{page.slug}/history/#{rev.id}']"
           )
  end

  test "a version saved with only blank lines changed says so", %{
    conn: conn,
    board: board,
    user: user
  } do
    page = page_fixture(board, %{"title" => "Blank", "body" => "a\nb"}, user: user)
    {:ok, page} = Wiki.update_page(page, %{"body" => "a\n\n\nb"}, user: user, new_revision: true)
    [rev | _] = Wiki.list_revisions(page)

    view = history(conn, board, page)
    open(view, rev)
    assert has_element?(view, "#revision-preview-#{rev.id}", "No lines changed.")
  end

  test "an id that isn't one of the listed versions opens nothing", %{conn: conn} = ctx do
    view = history(conn, ctx.board, ctx.page)
    render_click(view, "history_preview", %{"id" => "999999999"})
    render_click(view, "history_preview", %{"id" => "nonsense"})
    refute has_element?(view, "[data-role=revision-preview]")
  end

  test "opened rows close again on the way back to the history", %{conn: conn} = ctx do
    view = history(conn, ctx.board, ctx.page)
    open(view, ctx.revs.added)

    render_patch(view, ~p"/boards/#{ctx.board}/wiki/#{ctx.page.slug}")
    render_patch(view, ~p"/boards/#{ctx.board}/wiki/#{ctx.page.slug}/history")
    refute has_element?(view, "[data-role=revision-preview]")
  end
end
