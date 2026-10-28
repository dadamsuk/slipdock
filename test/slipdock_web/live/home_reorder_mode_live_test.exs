defmodule SlipdockWeb.HomeReorderModeLiveTest do
  @moduledoc """
  The home page's Reorder mode (#1485): a button that makes every board,
  vault and multiboard tile its own drag handle, with its links and menus out
  of the way, switching the sort to "My order" and saving each drop.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Accounts, Multiboard, Vaults}

  setup %{user: user} do
    alpha = board_fixture(%{"name" => "Alpha", "code" => "alrmh"}, owner: user)
    zulu = board_fixture(%{"name" => "Zulu", "code" => "zurmh"}, owner: user)
    {:ok, vault} = Vaults.create_vault(user, %{"name" => "Notes"})
    [_, todo | _] = alpha.columns
    {:ok, mb} = Multiboard.create_saved(user, %{"name" => "Queue"}, %{lists: [todo.id]})

    %{alpha: alpha, zulu: zulu, vault: vault, mb: mb}
  end

  defp tiles(view) do
    ~r/\sdata-id="([^"]+)"/
    |> Regex.scan(view |> element("#boards") |> render())
    |> Enum.map(fn [_, id] -> id end)
  end

  defp sort(user), do: Accounts.get_user!(user.id).board_sort

  test "Reorder makes every tile the handle, and Done puts things back", %{conn: conn} = ctx do
    {:ok, view, _} = live(conn, ~p"/")

    assert has_element?(view, "#reorder-boards[aria-pressed=false]", "Reorder")
    assert has_element?(view, "#boards[data-handle='.board-handle']")
    refute has_element?(view, "#reorder-hint")
    assert has_element?(view, "#new-board-tile")

    view |> element("#reorder-boards") |> render_click()

    assert has_element?(view, "#reorder-boards[aria-pressed=true]", "Done")
    assert has_element?(view, "#reorder-hint", "Drag boards, vaults and multiboards")
    # No handle option: Sortable takes a press anywhere on a tile.
    refute has_element?(view, "#boards[data-handle]")
    assert has_element?(view, "#boards[data-reordering=true][data-disabled=false]")
    # The tiles' links and menus can't be pressed while the mode is on.
    assert has_element?(view, "#boards[class*='pointer-events-none']")
    refute has_element?(view, "#new-board-tile")
    refute has_element?(view, "#new-vault-tile")

    for id <- [ctx.alpha.id, ctx.zulu.id, "vault-#{ctx.vault.id}", "multiboard-#{ctx.mb.id}"] do
      assert to_string(id) in tiles(view)
    end

    view |> element("#reorder-hint button", "Done") |> render_click()

    assert has_element?(view, "#reorder-boards[aria-pressed=false]", "Reorder")
    refute has_element?(view, "#reorder-hint")
    assert has_element?(view, "#boards[data-handle='.board-handle']")
    refute has_element?(view, "#boards[data-reordering]")
    refute has_element?(view, "#boards[class*='pointer-events-none']")
    assert has_element?(view, "#new-board-tile")
  end

  test "the header button toggles it off too, and Escape leaves it", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/")

    view |> element("#reorder-boards") |> render_click()
    view |> element("#reorder-boards") |> render_click()
    refute has_element?(view, "#reorder-hint")

    view |> element("#reorder-boards") |> render_click()
    assert has_element?(view, "#reorder-hint")
    view |> element("#reorder-hint") |> render_keydown(%{"key" => "Escape"})
    refute has_element?(view, "#reorder-hint")
  end

  test "from another sort it switches to My order, saved", %{conn: conn, user: user} do
    {:ok, _} = Accounts.update_board_view(user, %{"board_sort" => "name"})
    {:ok, view, _} = live(conn, ~p"/")

    assert has_element?(view, "#boards[data-disabled=true]")
    view |> element("#reorder-boards") |> render_click()

    assert sort(user) == "manual"
    assert has_element?(view, "#board-sort option[value=manual][selected]")
    assert has_element?(view, "#boards[data-disabled=false]")
    assert has_element?(view, "#reorder-hint")
  end

  test "picking a sorted order ends the mode; picking My order keeps it", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/")
    view |> element("#reorder-boards") |> render_click()

    view |> element("#board-sort") |> render_change(%{"sort" => "manual"})
    assert has_element?(view, "#reorder-hint")

    view |> element("#board-sort") |> render_change(%{"sort" => "name"})
    refute has_element?(view, "#reorder-hint")
    assert has_element?(view, "#reorder-boards[aria-pressed=false]")
  end

  test "drops in the mode move boards, vaults and multiboards, and stay", %{conn: conn} = ctx do
    {:ok, view, _} = live(conn, ~p"/")
    view |> element("#reorder-boards") |> render_click()

    vault = "vault-#{ctx.vault.id}"
    mb = "multiboard-#{ctx.mb.id}"
    alpha = to_string(ctx.alpha.id)
    zulu = to_string(ctx.zulu.id)

    render_hook(view, "reorder", %{"id" => mb, "before" => nil})
    render_hook(view, "reorder", %{"id" => vault, "before" => mb})
    render_hook(view, "reorder", %{"id" => zulu, "before" => alpha})
    assert tiles(view) == [zulu, alpha, vault, mb]
    # Still reordering after each drop.
    assert has_element?(view, "#reorder-hint")

    render_hook(view, "reorder", %{"id" => mb, "before" => zulu})
    assert tiles(view) == [mb, zulu, alpha, vault]

    # Kept: a fresh visit lists them the same way, out of the mode.
    {:ok, again, _} = live(conn, ~p"/")
    assert tiles(again) == [mb, zulu, alpha, vault]
    refute has_element?(again, "#reorder-hint")
  end

  test "works in the compact list too", %{conn: conn} = ctx do
    {:ok, view, _} = live(conn, ~p"/")
    view |> element("button[phx-value-layout=compact]") |> render_click()
    view |> element("#reorder-boards") |> render_click()

    assert has_element?(view, "tbody#boards[data-reordering=true]")
    refute has_element?(view, "tbody#boards[data-handle]")
    assert has_element?(view, "tbody#boards[class*='pointer-events-none']")

    render_hook(view, "reorder", %{"id" => to_string(ctx.zulu.id), "before" => nil})
    assert List.last(tiles(view)) == to_string(ctx.zulu.id)

    view |> element("#reorder-boards") |> render_click()
    assert has_element?(view, "tbody#boards[data-handle='.board-handle']")
  end

  test "archived boards stay out of it", %{conn: conn, user: user} do
    old = board_fixture(%{"name" => "Old", "code" => "olrmh"}, owner: user)
    {:ok, _} = Slipdock.Boards.archive_board(old)
    {:ok, view, _} = live(conn, ~p"/")

    view |> element("#reorder-boards") |> render_click()
    view |> element("button[phx-click=toggle_archived]") |> render_click()

    assert has_element?(view, "#archived-boards[data-disabled=true]")
    refute has_element?(view, "#archived-boards[data-reordering]")
  end

  test "with one tile there is nothing to reorder", %{conn: conn} do
    user = user_fixture("solo-reorder@example.com")
    board_fixture(%{"name" => "Only", "code" => "onrmh"}, owner: user)
    {:ok, view, _} = live(log_in_user(conn, user), ~p"/")

    refute has_element?(view, "#reorder-boards")
  end
end
