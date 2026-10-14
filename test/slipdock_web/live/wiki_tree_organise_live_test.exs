defmodule SlipdockWeb.WikiTreeOrganiseLiveTest do
  @moduledoc """
  Organising from the wiki's tree (W-103 R11.8-R11.10): its menu's Move,
  Also file in, Sort and New drawing; picking several rows to move, archive
  or tag; and moving a page to another board of the vault, which asks first.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures
  import SlipdockWeb.WikiTreeHelpers
  import Ecto.Query

  alias Slipdock.{Repo, Vaults, Wiki}
  alias Slipdock.Wiki.{Page, Placements}

  setup %{user: user} do
    kb = board_fixture(%{"name" => "KB", "code" => "kborg"}, owner: user)
    jobs = board_fixture(%{"name" => "Journal Desk", "code" => "jobsorg"}, owner: user)
    {:ok, vault} = Vaults.create_vault(user, %{"name" => "Brain"})
    {:ok, _} = Vaults.add_mapping(vault, user, %{path: "/", board: kb})
    {:ok, _} = Vaults.add_mapping(vault, user, %{path: "/Journal", board: jobs})
    {:ok, specs} = Wiki.create_folder(kb, %{"name" => "Specs"})
    {:ok, acme} = Wiki.create_folder(jobs, %{"name" => "Acme"})
    one = page_fixture(kb, %{"title" => "One"})
    two = page_fixture(kb, %{"title" => "Two"})
    %{kb: kb, jobs: jobs, specs: specs, acme: acme, one: one, two: two}
  end

  defp dialog(view, kind, keys),
    do: render_hook(view, "tree_dialog", %{"kind" => kind, "keys" => keys})

  test "Move… within the board files the pages at once", %{
    conn: conn,
    kb: kb,
    specs: specs,
    one: one,
    two: two
  } do
    {:ok, view, _} = live(conn, ~p"/boards/#{kb}/wiki")

    html = dialog(view, "move", ["page:#{one.id}", "page:#{two.id}"])
    assert html =~ "Move 2 items to…"
    assert has_element?(view, "#tree-targets button[phx-value-target='folder:#{specs.id}']")

    # Typing narrows the list.
    view |> form("#tree-target-filter", %{"q" => "spe"}) |> render_change()
    refute has_element?(view, "#tree-targets button[phx-value-target='board:#{kb.id}']")

    html =
      view
      |> element("#tree-targets button[phx-value-target='folder:#{specs.id}']")
      |> render_click()

    assert html =~ "Moved 2 items."
    assert Wiki.get_page!(one.id).folder_id == specs.id
    assert Wiki.get_page!(two.id).folder_id == specs.id
  end

  test "Move… to another board shows what goes and what stays, then moves", %{
    conn: conn,
    kb: kb,
    jobs: jobs,
    acme: acme,
    one: one
  } do
    tag = tag_fixture(kb, "Only here")
    {:ok, _} = Wiki.set_tags(one, [tag])
    {:ok, view, _} = live(conn, ~p"/boards/#{kb}/wiki/#{one.slug}")

    dialog(view, "move", ["page:#{one.id}"])

    html =
      view
      |> element("#tree-targets button[phx-value-target='folder:#{acme.id}']")
      |> render_click()

    assert html =~ "Move “One” to Journal Desk?"
    assert has_element?(view, "#cross-move-losses", "Only here")
    assert Wiki.get_page!(one.id).board_id == kb.id

    view |> element("#cross-move-confirm") |> render_click()
    moved = Repo.get!(Page, one.id)
    assert moved.board_id == jobs.id
    assert moved.folder_id == acme.id
    assert moved.code == one.code
    # The page being read went with it.
    assert_redirect(view, ~p"/boards/#{jobs}/wiki/#{moved.slug}")
  end

  test "a drag in the vault's tree to another board asks first", %{
    conn: conn,
    kb: kb,
    jobs: jobs,
    one: one
  } do
    {:ok, view, _} = live(conn, ~p"/boards/#{kb}/wiki")
    view |> element("button[phx-click='toggle_organise']") |> render_click()

    # Rows of both boards can be moved by this writer, from the board's own
    # wiki, which shows the vault from where it is mounted down (#758).
    reply = tree_load(view, %{"keys" => ["board:#{jobs.id}"]})
    assert %{writable: true} = row(reply, "root", "One")

    html =
      render_click(view, "tree_move", %{
        "kind" => "page",
        "id" => to_string(one.id),
        "into" => "board:#{jobs.id}",
        "before" => nil
      })

    assert html =~ "Move “One” to Journal Desk?"
    view |> element("#cross-move-confirm") |> render_click()
    assert Repo.get!(Page, one.id).board_id == jobs.id
  end

  test "a folder dragged to another board asks first, then moves with its pages", ctx do
    %{conn: conn, kb: kb, jobs: jobs, specs: specs} = ctx
    {:ok, inside} = Wiki.file_page(ctx.two, specs)
    {:ok, view, _} = live(conn, ~p"/boards/#{kb}/wiki")

    html =
      render_click(view, "tree_move", %{
        "kind" => "folder",
        "id" => to_string(specs.id),
        "into" => "board:#{jobs.id}",
        "before" => nil
      })

    assert html =~ "Move the folder “Specs” to Journal Desk?"
    assert has_element?(view, "#cross-move-folders", "1 folder, 1 page")
    assert Wiki.get_folder(specs.id).board_id == kb.id

    html = view |> element("#cross-move-confirm") |> render_click()
    assert html =~ "Moved 1 folder to Journal Desk."
    assert Wiki.get_folder(specs.id).board_id == jobs.id
    assert %{board_id: jid, folder_id: fid} = Repo.get!(Page, inside.id)
    assert {jid, fid} == {jobs.id, specs.id}
  end

  test "Move… with a folder and pages: one report, and a page inside the folder moves once",
       ctx do
    %{conn: conn, kb: kb, jobs: jobs, acme: acme, specs: specs, one: one, two: two} = ctx
    {:ok, two} = Wiki.file_page(two, specs)
    tag = tag_fixture(kb, "Only here")
    {:ok, _} = Wiki.set_tags(two, [tag])
    {:ok, view, _} = live(conn, ~p"/boards/#{kb}/wiki")

    dialog(view, "move", ["folder:#{specs.id}", "page:#{two.id}", "page:#{one.id}"])

    html =
      view
      |> element("#tree-targets button[phx-value-target='folder:#{acme.id}']")
      |> render_click()

    assert html =~ "Move 2 items to Journal Desk?"
    assert has_element?(view, "#cross-move-folders", "1 folder, 2 pages")
    assert has_element?(view, "#cross-move-losses", "Only here")

    html = view |> element("#cross-move-confirm") |> render_click()
    assert html =~ "Moved 1 folder and 1 page to Journal Desk."
    assert Wiki.get_folder(specs.id).parent_id == acme.id
    assert Repo.get!(Page, two.id).folder_id == specs.id
    assert Repo.get!(Page, one.id).board_id == jobs.id
  end

  test "a folder that can't go says why, and nothing moves", ctx do
    %{conn: conn, kb: kb, jobs: jobs, specs: specs} = ctx
    {:ok, _} = Wiki.create_folder(jobs, %{"name" => "Specs"})
    {:ok, view, _} = live(conn, ~p"/boards/#{kb}/wiki")

    html =
      render_click(view, "tree_move", %{
        "kind" => "folder",
        "id" => to_string(specs.id),
        "into" => "board:#{jobs.id}",
        "before" => nil
      })

    assert html =~ "can&#39;t move to Journal Desk: Journal Desk already has a folder named Specs"
    refute has_element?(view, "#cross-move-confirm")
    assert Wiki.get_folder(specs.id).board_id == kb.id
  end

  test "Also file in… adds a placement beside the page's home", %{
    conn: conn,
    kb: kb,
    acme: acme,
    one: one
  } do
    {:ok, view, _} = live(conn, ~p"/boards/#{kb}/wiki")
    html = dialog(view, "also", ["page:#{one.id}"])
    assert html =~ "Also file “One” in…"
    # Only folders: a placement is in a folder.
    refute has_element?(view, "#tree-targets button[phx-value-target^='board:']")

    view
    |> element("#tree-targets button[phx-value-target='folder:#{acme.id}']")
    |> render_click()

    assert [%{id: id}] = Placements.folders(Repo.get!(Page, one.id))
    assert id == acme.id
  end

  test "a page also filed in a folder shows there, and can be taken out", %{
    conn: conn,
    kb: kb,
    specs: specs,
    one: one
  } do
    {:ok, _} = Placements.add(one, specs, Slipdock.Accounts.get_user!(kb.owner_id))
    {:ok, view, _} = live(conn, ~p"/boards/#{kb}/wiki")

    reply = tree_load(view, %{"keys" => ["folder:#{specs.id}"]})
    assert %{also: true, placed_in: placed_in, key: key} = row(reply, "folder:#{specs.id}", "One")
    assert placed_in == specs.id
    assert key == "page:#{one.id}"
    # Its home row is still at the top of the wiki.
    refute Map.has_key?(row(reply, "root", "One"), :also)

    html =
      render_hook(view, "remove_placement", %{
        "id" => to_string(one.id),
        "folder" => to_string(specs.id)
      })

    assert html =~ "no longer filed in Specs"
    assert Placements.folders(Repo.get!(Page, one.id)) == []
    assert Repo.get!(Page, one.id).archived_at == nil
  end

  test "several picked are archived after asking, or tagged", %{
    conn: conn,
    kb: kb,
    one: one,
    two: two
  } do
    tag = tag_fixture(kb, "Ops")
    {:ok, view, _} = live(conn, ~p"/boards/#{kb}/wiki")

    dialog(view, "tag", ["page:#{one.id}", "page:#{two.id}"])
    html = view |> element("#bulk-tags button", "Ops") |> render_click()
    assert html =~ "Tagged 2 pages “Ops”."
    assert Enum.map(Wiki.tags(Repo.get!(Page, two.id)), & &1.id) == [tag.id]

    html = dialog(view, "archive", ["page:#{one.id}", "page:#{two.id}", "junk"])
    assert html =~ "Archive 2 pages?"
    view |> element("#bulk-archive-confirm") |> render_click()
    refute is_nil(Repo.get!(Page, one.id).archived_at)
    refute is_nil(Repo.get!(Page, two.id).archived_at)
  end

  test "sorting a folder and the top of the board", %{conn: conn, kb: kb, specs: specs} do
    {:ok, view, _} = live(conn, ~p"/boards/#{kb}/wiki")

    # By name until someone chooses (#789); a folder follows the top.
    assert tree_load(view).sort == "name"
    refute Map.has_key?(row(tree_load(view), "root", "Specs"), :sort)

    render_hook(view, "set_tree_sort", %{"key" => "folder:#{specs.id}", "sort" => "name"})
    assert Wiki.get_folder(specs.id).sort == "name"
    assert %{sort: "name"} = row(tree_load(view), "root", "Specs")

    render_hook(view, "set_tree_sort", %{"key" => "root", "sort" => "modified"})
    assert Slipdock.Boards.get_board!(kb.id).wiki_sort == "modified"
    assert tree_load(view).sort == "modified"

    render_hook(view, "set_tree_sort", %{"key" => "folder:#{specs.id}", "sort" => "manual"})
    assert %{sort: "manual"} = row(tree_load(view), "root", "Specs")

    # Back to following the top.
    render_hook(view, "set_tree_sort", %{"key" => "folder:#{specs.id}", "sort" => "board"})
    assert Wiki.get_folder(specs.id).sort == nil
    refute Map.has_key?(row(tree_load(view), "root", "Specs"), :sort)

    assert render_hook(view, "set_tree_sort", %{"key" => "root", "sort" => "random"}) =~ "sort by"
    assert render_hook(view, "set_tree_sort", %{"key" => "root", "sort" => "board"}) =~ "sort by"
  end

  test "New drawing makes an Excalidraw note in the folder and opens it in the editor", %{
    conn: conn,
    kb: kb,
    specs: specs
  } do
    {:ok, view, _} = live(conn, ~p"/boards/#{kb}/wiki")
    render_hook(view, "new_drawing", %{"key" => "folder:#{specs.id}"})

    [drawing] = Repo.all(from(p in Page, where: p.folder_id == ^specs.id))
    assert drawing.title =~ ~r/^Drawing \d{4}-\d\d-\d\d \d\d\.\d\d\.\d\d$/
    assert drawing.file_name == drawing.title <> ".excalidraw"
    assert drawing.front_matter =~ "excalidraw-plugin: parsed"
    assert drawing.body =~ ~s("type":"excalidraw")
    assert_redirect(view, ~p"/drawings/page/#{drawing.id}")
    # Which the plugin's reader, and so Slipdock's, takes for an empty drawing.
    assert {:ok, %{scene: %{"elements" => []}, format: :json}} =
             Slipdock.Wiki.Excalidraw.parse_markdown(drawing.body)
  end

  describe "folders are only acted on where the reader can write" do
    setup %{user: user} do
      stranger = user_fixture("org.stranger@example.com")
      theirs = board_fixture(%{"name" => "Theirs", "code" => "theirsorg"}, owner: stranger)
      {:ok, their_folder} = Wiki.create_folder(theirs, %{"name" => "Private"})
      %{their_folder: their_folder, user: user}
    end

    test "renaming or deleting another board's folder by its id does nothing", %{
      conn: conn,
      kb: kb,
      their_folder: their_folder
    } do
      {:ok, view, _} = live(conn, ~p"/boards/#{kb}/wiki")

      render_hook(view, "rename_folder", %{"id" => to_string(their_folder.id)})
      refute has_element?(view, "#folder-modal")
      render_hook(view, "ask_delete_folder", %{"id" => to_string(their_folder.id)})
      render_hook(view, "delete_folder", %{"id" => to_string(their_folder.id), "how" => "purge"})

      render_hook(view, "set_tree_sort", %{"key" => "folder:#{their_folder.id}", "sort" => "name"})

      dialog(view, "move", ["folder:#{their_folder.id}"])
      refute has_element?(view, "#tree-prompt")

      folder = Wiki.get_folder(their_folder.id)
      assert folder.name == "Private"
      assert folder.sort == nil
    end

    test "a folder cannot be filed inside another board's", %{
      conn: conn,
      kb: kb,
      specs: specs,
      their_folder: their_folder
    } do
      {:ok, view, _} = live(conn, ~p"/boards/#{kb}/wiki?folder=#{specs.id}")
      view |> element("button[phx-click='rename_folder']") |> render_click()

      html =
        view
        |> element("#folder-form")
        |> render_submit(%{"name" => "Specs", "parent_id" => to_string(their_folder.id)})

      assert html =~ "inside a folder on its own board"
      assert Wiki.get_folder(specs.id).parent_id == nil
    end

    test "a reader cannot make a folder", %{kb: kb, user: owner} do
      reader = user_fixture("org.reader@example.com")
      {:ok, _} = Slipdock.Access.grant(kb, reader, "read", owner)
      {:ok, view, _} = live(conn_as(reader), ~p"/boards/#{kb}/wiki")

      assert render_hook(view, "save_folder", %{"name" => "Sneaky"}) =~ "can&#39;t write"
      assert {:error, _, _} = Wiki.find_folder(kb, "Sneaky")
    end
  end
end
