defmodule SlipdockWeb.PagePanelAccessLiveTest do
  @moduledoc """
  The page panel (`?page=<id>`, `BoardLive.PageComponent`) opens a page only
  for a reader who may see the page itself: `Wiki.visible?/2` at their
  `Access.page_permission/2`. Being able to open the board, a view of it or
  one of its cards is not enough (#2748).
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Access, Boards, Wiki}
  alias Slipdock.Swimlanes.Config

  setup %{user: owner} do
    board = board_fixture(%{"name" => "Panelled"}, owner: owner)
    column = hd(board.columns)
    card = card_fixture(column, %{"title" => "Shared card"})

    page =
      page_fixture(board, %{"title" => "Placed page", "summary" => "Inner summary"}, user: owner)

    {:ok, _} = Wiki.place(page, column)

    draft =
      page_fixture(board, %{"title" => "Draft page", "status" => "draft"}, user: owner)

    {:ok, _} = Wiki.place(draft, column)

    %{board: board, column: column, card: card, page: page, draft: draft, owner: owner}
  end

  defp as(user), do: log_in_user(build_conn(), user)

  defp refute_panel(view, page) do
    refute has_element?(view, "#page-panel")
    refute render(view) =~ page.code
  end

  test "the owner sees the panel for a placed page and a draft", ctx do
    {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}?#{[page: ctx.page.id]}")
    assert has_element?(view, "#page-panel", "Placed page")

    {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}?#{[page: ctx.draft.id]}")
    assert has_element?(view, "#page-panel", "Draft page")
  end

  test "a view-only user sees no page in the panel", ctx do
    viewer = user_fixture("viewer@example.com")

    {:ok, saved} =
      Boards.create_saved_view(ctx.board, %{
        "name" => "Everything",
        "config" => Config.to_map(Config.defaults("table"))
      })

    {:ok, _} = Access.grant(saved, viewer, "read", ctx.owner)
    assert Access.board_permission(viewer, ctx.board) == :view
    assert Access.page_permission(viewer, ctx.page) == :none

    {:ok, view, _} =
      live(as(viewer), ~p"/boards/#{ctx.board}/table?#{[view: saved.id, page: ctx.page.id]}")

    refute_panel(view, ctx.page)

    # And nothing it is sent does anything to the page.
    view |> with_target("#board-page") |> render_click("add_comment", %{"body" => "hi"})
    assert Slipdock.Repo.preload(Wiki.get_page!(ctx.page.id), :comments).comments == []
  end

  test "a card-only guest sees no page in the panel over their card", ctx do
    guest = user_fixture("guest@example.com")
    {:ok, _} = Access.grant(ctx.card, guest, "write", ctx.owner)
    assert Access.page_permission(guest, ctx.page) == :none

    {:ok, view, _} =
      live(as(guest), ~p"/boards/#{ctx.board}/cards/#{ctx.card}?#{[page: ctx.page.id]}")

    assert has_element?(view, "#card-modal", "Shared card")
    refute_panel(view, ctx.page)
  end

  test "a reader sees a published page, but not a draft", ctx do
    reader = user_fixture("reader@example.com")
    {:ok, _} = Access.grant(ctx.board, reader, "read", ctx.owner)

    {:ok, view, _} = live(as(reader), ~p"/boards/#{ctx.board}?#{[page: ctx.page.id]}")
    assert has_element?(view, "#page-panel", "Placed page")
    assert has_element?(view, "#page-panel", "read-only access")

    {:ok, view, _} = live(as(reader), ~p"/boards/#{ctx.board}?#{[page: ctx.draft.id]}")
    refute_panel(view, ctx.draft)
  end

  test "a commenter doesn't see a draft either", ctx do
    commenter = user_fixture("commenter@example.com")
    {:ok, _} = Access.grant(ctx.board, commenter, "comment", ctx.owner)

    {:ok, view, _} = live(as(commenter), ~p"/boards/#{ctx.board}?#{[page: ctx.draft.id]}")
    refute_panel(view, ctx.draft)
  end

  test "a writer sees a draft", ctx do
    writer = user_fixture("writer@example.com")
    {:ok, _} = Access.grant(ctx.board, writer, "write", ctx.owner)

    {:ok, view, _} = live(as(writer), ~p"/boards/#{ctx.board}?#{[page: ctx.draft.id]}")
    assert has_element?(view, "#page-panel", "Draft page")
  end

  test "a reader given write on a draft by a share sees it", ctx do
    reader = user_fixture("shared-reader@example.com")
    {:ok, _} = Access.grant(ctx.board, reader, "read", ctx.owner)
    {:ok, _} = Access.grant(ctx.draft, reader, "write", ctx.owner)
    assert Access.board_permission(reader, ctx.board) == :read
    assert Access.page_permission(reader, ctx.draft) == :write

    {:ok, view, _} = live(as(reader), ~p"/boards/#{ctx.board}?#{[page: ctx.draft.id]}")
    assert has_element?(view, "#page-panel", "Draft page")
    refute has_element?(view, "#page-panel", "read-only access")
  end

  test "a view-only user given read on a page by a share sees it", ctx do
    viewer = user_fixture("shared-viewer@example.com")

    {:ok, saved} =
      Boards.create_saved_view(ctx.board, %{
        "name" => "Everything",
        "config" => Config.to_map(Config.defaults("table"))
      })

    {:ok, _} = Access.grant(saved, viewer, "read", ctx.owner)
    {:ok, _} = Access.grant(ctx.page, viewer, "read", ctx.owner)
    assert Access.board_permission(viewer, ctx.board) == :view
    assert Access.page_permission(viewer, ctx.page) == :read

    {:ok, view, _} =
      live(as(viewer), ~p"/boards/#{ctx.board}/table?#{[view: saved.id, page: ctx.page.id]}")

    assert has_element?(view, "#page-panel", "Placed page")
  end
end
