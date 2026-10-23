defmodule SlipdockWeb.VaultRecentLiveTest do
  @moduledoc """
  The vault view's middle column (#1211): the tree beside it has the
  folders, so instead of folder cards it lists the notes edited most lately
  under whichever folder is open, at any depth, newest first, or across the
  whole vault when none is.
  """
  use SlipdockWeb.ConnCase, async: true

  import Ecto.Query
  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Repo, Vaults, Wiki}
  alias Slipdock.Wiki.Page

  setup %{user: user} do
    kb = board_fixture(%{"name" => "Keystone", "code" => "kbrec"}, owner: user)
    hunt = board_fixture(%{"name" => "Journal Desk", "code" => "huntrec"}, owner: user)
    {:ok, ideas} = Wiki.create_folder(kb, %{"name" => "Big Ideas"})
    {:ok, deep} = Wiki.create_folder(kb, %{"name" => "Deeper", "parent_id" => ideas.id})
    {:ok, empty} = Wiki.create_folder(kb, %{"name" => "Nothing Yet"})

    top = page(kb, "Top note", nil, ~U[2026-01-01 09:00:00Z])
    idea = page(kb, "Plain text", ideas.id, ~U[2026-02-01 09:00:00Z])
    nested = page(kb, "Buried note", deep.id, ~U[2026-05-01 09:00:00Z])
    journal = page(hunt, "Intake Questions", nil, ~U[2026-03-01 09:00:00Z])

    {:ok, vault} = Vaults.create_vault(user, %{"name" => "RecentNotes"})
    {:ok, _} = Vaults.add_mapping(vault, user, %{path: "/", board: kb})
    {:ok, _} = Vaults.add_mapping(vault, user, %{path: "/Journal", board: hunt})

    %{
      kb: kb,
      ideas: ideas,
      empty: empty,
      top: top,
      idea: idea,
      nested: nested,
      journal: journal
    }
  end

  defp page(board, title, folder_id, at) do
    {:ok, page} =
      Wiki.create_page(board, %{
        "title" => title,
        "body" => "About #{title}.",
        "folder_id" => folder_id
      })

    Repo.update_all(from(p in Page, where: p.id == ^page.id), set: [updated_at: at])
    page
  end

  defp listed(view) do
    Regex.scan(~r/id="vault-recent-(\d+)"/, render(view))
    |> Enum.map(fn [_, id] -> String.to_integer(id) end)
  end

  test "with no folder open, the newest notes from every folder and board", ctx do
    {:ok, view, _} = live(ctx.conn, "/vaults/RecentNotes")

    assert listed(view) == [ctx.nested.id, ctx.journal.id, ctx.idea.id, ctx.top.id]
    # No folder cards: the tree is the filing.
    refute render(view) =~ "Download the whole wiki"
    refute has_element?(view, "h2", "Folders")
    # Each says where it is, and opens at its vault address.
    assert has_element?(
             view,
             "#vault-recent-#{ctx.nested.id} .vault-recent-where",
             "Big Ideas / Deeper"
           )

    assert has_element?(view, "#vault-recent-#{ctx.journal.id} .vault-recent-where", "Journal")
    refute has_element?(view, "#vault-recent-#{ctx.top.id} .vault-recent-where")

    assert has_element?(
             view,
             "#vault-recent-#{ctx.idea.id} a[href='/vaults/RecentNotes/Big%20Ideas/Plain%20text']"
           )
  end

  test "a folder lists what is in it and in the folders inside it, newest first", ctx do
    {:ok, view, _} = live(ctx.conn, "/vaults/RecentNotes/Big%20Ideas")

    assert listed(view) == [ctx.nested.id, ctx.idea.id]
    # Where is said from the folder down, not from the top of the vault.
    assert has_element?(view, "#vault-recent-#{ctx.nested.id} .vault-recent-where", "Deeper")
    refute has_element?(view, "#vault-recent-#{ctx.idea.id} .vault-recent-where")
    # The folder's own heading and actions stay; its folder and page lists go.
    assert has_element?(view, "h1", "Big Ideas")
    refute has_element?(view, "h2", "Folders")
    refute has_element?(view, "h2", "Pages")
  end

  test "a board mounted at a path lists only its own notes", ctx do
    {:ok, view, html} = live(ctx.conn, "/vaults/RecentNotes/Journal")

    assert listed(view) == [ctx.journal.id]
    assert html =~ "in this folder and the ones inside it"
  end

  test "an empty folder says so rather than listing nothing", ctx do
    {:ok, view, _} = live(ctx.conn, "/vaults/RecentNotes/Nothing%20Yet")

    assert listed(view) == []
    assert has_element?(view, "#vault-recent", "No notes in this folder yet.")
  end

  test "a note edited moves to the top of its folder's list", ctx do
    {:ok, _} = Wiki.update_page(ctx.idea, %{"body" => "Changed just now."})
    {:ok, view, _} = live(ctx.conn, "/vaults/RecentNotes/Big%20Ideas")

    assert listed(view) == [ctx.idea.id, ctx.nested.id]
  end

  test "a board's own wiki keeps its folder cards", ctx do
    {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.kb}/wiki")

    assert has_element?(view, "h2", "Folders")
    refute has_element?(view, "#vault-recent")

    {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.kb}/wiki?#{[folder: ctx.ideas.id]}")
    assert has_element?(view, "h2", "Pages")
    refute has_element?(view, "#vault-recent")
  end
end
