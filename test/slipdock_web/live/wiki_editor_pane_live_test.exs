defmodule SlipdockWeb.WikiEditorPaneLiveTest do
  @moduledoc """
  The wiki editor as one pane (#1744): the live-preview editor alone at the
  whole width, encryption in its ⋯ menu unless the page already holds a
  secret, and Save, Cancel and Preview at their weights in the button
  hierarchy. In Chromium: `tools/e2e/wiki-editor.sh`.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  @secret "Door code: 🔐β 💡the usual💡U2FsdGVkX19abcdefghijklmnop= 🔐"

  setup %{user: user} do
    board = board_fixture(%{"name" => "Editor EP"}, owner: user)
    plain = page_fixture(board, %{"title" => "Plain", "body" => "## Notes\n\nNothing secret."})
    secret = page_fixture(board, %{"title" => "Vaulted", "body" => @secret})
    %{board: board, plain: plain, secret: secret}
  end

  defp edit(conn, board, page) do
    {:ok, view, _} = live(conn, ~p"/boards/#{board}/wiki/#{page.slug}/edit")
    view
  end

  test "an ordinary page opens in one pane, the whole width", %{conn: conn} = ctx do
    view = edit(conn, ctx.board, ctx.plain)

    assert has_element?(view, "#wiki-column.max-w-none")
    assert has_element?(view, "#page-body-paste")
    refute has_element?(view, "#page-preview")
    refute has_element?(view, "#page-form .lg\\:grid-cols-2")
  end

  test "on an ordinary page, encryption waits in the editor's ⋯ menu", %{conn: conn} = ctx do
    view = edit(conn, ctx.board, ctx.plain)

    assert has_element?(view, "#meld-tools[phx-hook=MeldEditor][data-encrypted=false]")
    assert has_element?(view, "#meld-tools #editor-menu[aria-label='More editor actions']")

    for action <- ~w(encrypt whole edit) do
      assert has_element?(view, "#editor-menu-items li > button[data-meld-action=#{action}]")
    end

    assert has_element?(view, "#editor-menu-items", "Encrypt whole note")
    assert has_element?(view, "#editor-menu-items", "Decrypt to edit")
    # Not in the row as buttons of their own.
    refute has_element?(view, "#meld-tools > button[data-meld-action]")
    # The purge choice still goes with the form.
    assert has_element?(view, "#page-form #meld-tools input[name=purge_revisions]")
  end

  test "on an encrypted page, the actions stand in the row", %{conn: conn} = ctx do
    view = edit(conn, ctx.board, ctx.secret)

    assert has_element?(view, "#meld-tools[data-encrypted=true]")
    refute has_element?(view, "#editor-menu")

    for action <- ~w(encrypt whole edit) do
      assert has_element?(view, "#meld-tools > button.btn-ghost[data-meld-action=#{action}]")
    end

    assert has_element?(view, "#meld-tools > button[data-meld-action=edit]", "Decrypt to edit")
  end

  test "a new page has the menu, and no secret to show the actions for", %{conn: conn} = ctx do
    {:ok, view, _} = live(conn, ~p"/boards/#{ctx.board}/wiki/new")

    assert has_element?(view, "#meld-tools[data-encrypted=false] #editor-menu")
    refute has_element?(view, "#page-preview")
  end

  test "Save is the one primary, Cancel and Preview are tertiary", %{conn: conn} = ctx do
    view = edit(conn, ctx.board, ctx.plain)

    assert has_element?(view, "#save-page.btn.btn-primary[type=submit]", "Save")
    assert has_element?(view, "#cancel-edit.btn.btn-ghost", "Cancel")
    refute has_element?(view, "#cancel-edit.btn-primary, #cancel-edit.btn-secondary")
    assert has_element?(view, "#toggle-preview.btn.btn-ghost")
    refute has_element?(view, "#page-form .btn-soft")

    html = view |> element("#page-form") |> render()
    assert length(Regex.scan(~r/\bbtn-primary\b/, html)) == 1
  end

  test "Cancel still leaves the editor, and Save still saves", %{conn: conn} = ctx do
    view = edit(conn, ctx.board, ctx.plain)
    view |> element("#cancel-edit") |> render_click()
    assert_redirect(view, ~p"/boards/#{ctx.board}/wiki/#{ctx.plain.slug}")

    view = edit(conn, ctx.board, ctx.plain)

    view
    |> form("#page-form", page: %{title: "Plain", body: "Changed."})
    |> render_submit()

    assert Slipdock.Wiki.get_page!(ctx.plain.id).body == "Changed."
  end
end
