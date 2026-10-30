defmodule SlipdockWeb.QuickNoteLiveTest do
  @moduledoc "The quick note overlay and its setting (#1538)."
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Accounts, Repo, Vaults, Wiki}

  setup %{user: user} do
    board = board_fixture(%{"name" => "Brain QL"})
    {:ok, inbox} = Wiki.create_folder(board, %{"name" => "Inbox"})
    {:ok, vault} = Vaults.create_vault(user, %{"name" => "Mind"})
    {:ok, _} = Vaults.add_mapping(vault, user, %{path: "/", board: board})
    %{board: board, vault: vault, inbox: inbox}
  end

  defp open(view), do: view |> element("#quick-note-open") |> render_click()

  defp submit(view, text, key \\ 0),
    do: view |> form("#quick-note-form-#{key}", %{"text" => text}) |> render_submit()

  test "the button opens it, Save files it and says where", %{conn: conn, board: board} do
    Slipdock.AIStub.reply_with(%{"title" => "Printers", "folder" => "Inbox"})
    {:ok, view, _html} = live(conn, ~p"/")
    refute has_element?(view, "#quick-note-panel")

    open(view)
    submit(view, "ring the printers")
    html = render_async(view)

    assert has_element?(view, "#quick-note-where", "Mind / Inbox")
    assert html =~ "Printers"
    assert has_element?(view, "#quick-note-text-1", "")
    assert [page] = Wiki.list_pages(board)
    assert page.body == "ring the printers"
    assert page.title =~ ~r/^\d{4}-\d{2}-\d{2} \d{2}\.\d{2} Printers$/
  end

  test "it is on every signed-in page, and toggles", %{conn: conn, board: board} do
    for path <- [~p"/search", ~p"/boards/#{board.id}", ~p"/account/settings"] do
      {:ok, view, _html} = live(conn, path)
      open(view)
      assert has_element?(view, "#quick-note-panel")
      open(view)
      refute has_element?(view, "#quick-note-panel")
    end
  end

  test "an empty note is refused and nothing is written", %{conn: conn, board: board} do
    {:ok, view, _html} = live(conn, ~p"/")
    open(view)
    submit(view, "   ")

    assert has_element?(view, "#quick-note-error", "Write something first.")
    assert Wiki.list_pages(board) == []
  end

  test "a refused save keeps what was typed", %{conn: conn, user: user, vault: vault} do
    {:ok, _} = Vaults.delete_vault(vault)
    assert Vaults.list_vaults(user) == []

    {:ok, view, _html} = live(conn, ~p"/")
    open(view)
    submit(view, "keep this")
    render_async(view)

    assert has_element?(view, "#quick-note-error", "Make one under Vaults first.")
    assert has_element?(view, "#quick-note-text-0", "keep this")
  end

  test "closing keeps the draft for the next time it opens", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    open(view)
    view |> form("#quick-note-form-0", %{"text" => "half a thought"}) |> render_change()
    open(view)
    open(view)

    assert has_element?(view, "#quick-note-text-0", "half a thought")
  end

  test "the setting saves a vault and location, and notes follow it", ctx do
    {:ok, view, _html} = live(ctx.conn, ~p"/account/settings")

    view
    |> form("#quick-note-form", %{"location" => "#{ctx.vault.id}:Inbox"})
    |> render_submit()

    user = Repo.reload!(ctx.user)
    assert user.quick_note_vault_id == ctx.vault.id
    assert user.quick_note_folder == "Inbox"

    Slipdock.AIStub.reply_with(%{"title" => "T"})
    assert {:ok, %{location: "Inbox"}} = Slipdock.Wiki.QuickNote.save(user, "x")
  end

  test "the setting can be cleared", ctx do
    {:ok, user} =
      Accounts.update_quick_note(ctx.user, %{
        quick_note_vault_id: ctx.vault.id,
        quick_note_folder: "Inbox"
      })

    {:ok, view, _html} = live(ctx.conn, ~p"/account/settings")
    view |> form("#quick-note-form", %{"location" => ""}) |> render_submit()

    assert Repo.reload!(user).quick_note_vault_id == nil
  end

  test "somebody else's vault is refused by the setting", ctx do
    other = user_fixture("qnother@example.com")
    {:ok, theirs} = Vaults.create_vault(other, %{"name" => "Theirs"})

    {:ok, view, _html} = live(ctx.conn, ~p"/account/settings")

    view
    |> element("#quick-note-form")
    |> render_submit(%{"location" => "#{theirs.id}:"})

    assert Repo.reload!(ctx.user).quick_note_vault_id == nil
  end

  test "Shift-Alt-N is on the help sheet" do
    assert {"Shift-Alt-N", _} = List.keyfind(SlipdockWeb.Shortcuts.all(), "Shift-Alt-N", 0)
  end
end
