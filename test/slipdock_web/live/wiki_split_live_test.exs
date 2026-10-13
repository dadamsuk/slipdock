defmodule SlipdockWeb.WikiSplitLiveTest do
  @moduledoc "“Give it its own board…” on a vault folder in the wiki's tree (#747)."
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Repo, Vaults, Wiki}
  alias Slipdock.Wiki.{Folder, Page}

  setup %{user: user} do
    kb = board_fixture(%{"name" => "KnowledgeBase", "code" => "kbsl"}, owner: user)
    hunt = board_fixture(%{"name" => "Job Hunt", "code" => "huntsl"}, owner: user)
    {:ok, jobs} = Wiki.create_folder(kb, %{"name" => "Jobs"})
    {:ok, note} = Wiki.create_page(kb, %{"title" => "Acme", "folder_id" => jobs.id})
    {:ok, vault} = Vaults.create_vault(user, %{"name" => "GMinds"})
    {:ok, _} = Vaults.add_mapping(vault, user, %{path: "/", board: kb})
    %{kb: kb, hunt: hunt, jobs: jobs, note: note, vault: vault}
  end

  test "the tree knows the reader owns the vault", %{conn: conn, kb: kb} do
    {:ok, view, _} = live(conn, ~p"/boards/#{kb}/wiki")
    assert has_element?(view, "#wiki-tree[data-vault-owner=true]")
  end

  test "pick a board, see what a synced folder would see, then move and map", ctx do
    %{conn: conn, user: user, kb: kb, hunt: hunt, jobs: jobs, note: note, vault: vault} = ctx
    {:ok, _} = Wiki.create_page(hunt, %{"title" => "Already here"})
    {:ok, view, _} = live(conn, ~p"/boards/#{kb}/wiki")

    html = render_click(view, "split_folder", %{"id" => to_string(jobs.id)})
    assert html =~ "Give /Jobs its own board"
    assert has_element?(view, "#split-confirm[disabled]")
    # The folder's own board can't be picked.
    assert has_element?(
             view,
             "#split-form option[disabled]",
             "KnowledgeBase — the folder is on it already"
           )

    view |> form("#split-form", %{"board" => to_string(hunt.id)}) |> render_change()

    assert has_element?(
             view,
             "#split-preview",
             "1 page and 0 folders move from KnowledgeBase to Job Hunt"
           )

    assert has_element?(view, "#split-preview", "Synced folders: 1 file unchanged")
    assert has_element?(view, "#split-preview", "Jobs/Already here.md")
    # A preview changes nothing.
    assert Repo.get!(Page, note.id).board_id == kb.id

    html = view |> element("#split-confirm") |> render_click()
    assert html =~ "/Jobs is Job Hunt&#39;s now"
    assert Repo.get!(Page, note.id).board_id == hunt.id
    refute Repo.get(Folder, jobs.id)
    {:ok, vault} = Vaults.get_vault(user, vault.id)
    assert Enum.map(vault.mappings, & &1.path) == ["", "Jobs"]
  end

  test "a new board, by name", ctx do
    %{conn: conn, kb: kb, jobs: jobs, note: note} = ctx
    {:ok, view, _} = live(conn, ~p"/boards/#{kb}/wiki")
    render_click(view, "split_folder", %{"id" => to_string(jobs.id)})

    view |> form("#split-form", %{"board" => "new"}) |> render_change()
    assert has_element?(view, "#split-form input[name=new_name][value=Jobs]")

    view |> form("#split-form", %{"board" => "new", "new_name" => "Careers"}) |> render_change()
    assert has_element?(view, "#split-preview", "to a new board, Careers")

    view |> element("#split-confirm") |> render_click()

    assert %{name: "Careers"} =
             Repo.get!(Slipdock.Boards.Board, Repo.get!(Page, note.id).board_id)
  end

  test "a board that can't take the path says why, and Move stays off", ctx do
    %{conn: conn, user: user, kb: kb, hunt: hunt, jobs: jobs} = ctx
    {:ok, other} = Vaults.create_vault(user, %{"name" => "Other"})
    {:ok, _} = Vaults.add_mapping(other, user, %{path: "/", board: hunt})
    {:ok, view, _} = live(conn, ~p"/boards/#{kb}/wiki")

    render_click(view, "split_folder", %{"id" => to_string(jobs.id)})

    assert has_element?(
             view,
             "#split-form option[disabled]",
             "Job Hunt — is already in another vault"
           )

    # Sent by hand anyway, it is not a pick.
    view |> form("#split-form", %{"board" => to_string(hunt.id)}) |> render_change()
    refute has_element?(view, "#split-preview")
    assert has_element?(view, "#split-confirm[disabled]")
  end

  test "someone who doesn't own the vault isn't offered it, and can't ask", ctx do
    %{kb: kb, jobs: jobs} = ctx
    writer = user_fixture("writer-split@example.com")
    share_fixture(kb, writer, "write")
    {:ok, view, _} = live(conn_as(writer), ~p"/boards/#{kb}/wiki")

    assert has_element?(view, "#wiki-tree[data-vault-owner=false]")
    html = render_click(view, "split_folder", %{"id" => to_string(jobs.id)})
    assert html =~ "can&#39;t be given a board from here"
    refute has_element?(view, "#split-form")
  end
end
