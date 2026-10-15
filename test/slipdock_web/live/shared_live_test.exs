defmodule SlipdockWeb.SharedLiveTest do
  @moduledoc "Shared with me (#817): the view, its live updates, and what it never shows."
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Access, Boards, Wiki}

  setup do
    owner = user_fixture("owner@example.com")
    board = board_fixture(%{"name" => "Secret Board Name"}, owner: owner)
    {:ok, shared} = Wiki.create_folder(board, %{"name" => "Shared folder"})
    {:ok, private} = Wiki.create_folder(board, %{"name" => "Hidden folder name"})

    page =
      page_fixture(
        board,
        %{
          "title" => "Shared plan",
          "body" => "Nothing yet.",
          "folder_id" => shared.id
        },
        user: owner
      )

    sibling =
      page_fixture(board, %{"title" => "Sibling secret", "folder_id" => private.id}, user: owner)

    card = card_fixture(hd(board.columns), %{"title" => "Confidential card title"})
    # By code, so the shared page's own text doesn't name it: the link is
    # what must not give it away.
    {:ok, page} = Wiki.update_page(page, %{"body" => "See [[#{sibling.code}]] and ##{card.id}."})

    sharee = user_fixture("sharee@example.com")

    %{
      owner: owner,
      board: board,
      shared: shared,
      page: page,
      sibling: sibling,
      card: card,
      sharee: sharee,
      sharee_conn: conn_as(sharee)
    }
  end

  test "the view says when nothing is shared", c do
    {:ok, view, _html} = live(c.sharee_conn, ~p"/shared")
    assert has_element?(view, "#shared-empty")
  end

  test "a shared page opens in the share's view, rendered, and editable by a writer", c do
    {:ok, _} = Access.grant(c.page, c.sharee, "write", c.owner)
    {:ok, view, html} = live(c.sharee_conn, ~p"/shared/pages/#{c.page.id}")

    assert html =~ "Shared plan"
    assert has_element?(view, "#shared-tree a[data-key='page:#{c.page.id}']")
    view |> element("#shared-edit") |> render_click()

    view
    |> form("#shared-edit-form", page: %{title: "Shared plan v2", body: "New words."})
    |> render_submit()

    assert Wiki.get_page!(c.page.id).body == "New words."
    assert Wiki.get_page!(c.page.id).updated_by_id == c.sharee.id
  end

  test "a reader can't edit", c do
    {:ok, _} = Access.grant(c.page, c.sharee, "read", c.owner)
    {:ok, view, _html} = live(c.sharee_conn, ~p"/shared/pages/#{c.page.id}")
    refute has_element?(view, "#shared-edit")

    case live(c.sharee_conn, ~p"/shared/pages/#{c.page.id}/edit") do
      {:ok, edit, _} -> refute has_element?(edit, "#shared-edit-form")
      {:error, {_kind, %{to: to}}} -> assert to == "/shared/pages/#{c.page.id}"
    end

    render_submit(view, "save", %{"page" => %{"title" => "x", "body" => "y"}})
    assert Wiki.get_page!(c.page.id).title == "Shared plan"
  end

  test "a shared folder lists what is in it and lets a writer add a page and a folder", c do
    {:ok, _} = Access.grant(c.shared, c.sharee, "write", c.owner)
    {:ok, view, _html} = live(c.sharee_conn, ~p"/shared/folders/#{c.shared.id}")

    assert has_element?(view, "#shared-folder", "Shared plan")
    view |> form("#shared-new-folder", %{name: "Notes"}) |> render_submit()
    assert [notes] = Enum.filter(Wiki.folders(c.board), &(&1.name == "Notes"))
    assert notes.parent_id == c.shared.id

    {:ok, view, _html} = live(c.sharee_conn, ~p"/shared/folders/#{c.shared.id}")
    view |> form("#shared-new-page", %{title: "From the sharee"}) |> render_submit()
    assert [made] = Enum.filter(Wiki.list_pages(c.board), &(&1.title == "From the sharee"))
    assert made.folder_id == c.shared.id and made.created_by_id == c.sharee.id
  end

  test "revoking a share takes the row away live, and the open page with it", c do
    {:ok, grant} = Access.grant(c.page, c.sharee, "read", c.owner)
    {:ok, index, _html} = live(c.sharee_conn, ~p"/shared")
    assert has_element?(index, "#shared-tree a[data-key='page:#{c.page.id}']")

    {:ok, open, _html} = live(c.sharee_conn, ~p"/shared/pages/#{c.page.id}")

    {:ok, _} = Access.revoke(grant)

    refute has_element?(index, "#shared-tree a[data-key='page:#{c.page.id}']")
    assert has_element?(index, "#shared-empty")
    assert_redirect(open, ~p"/shared")
  end

  test "a share given while the view is open shows up live", c do
    {:ok, view, _html} = live(c.sharee_conn, ~p"/shared")
    assert has_element?(view, "#shared-empty")

    {:ok, _} = Access.grant(c.shared, c.sharee, "read", c.owner)

    assert has_element?(view, "#shared-tree [data-key='folder:#{c.shared.id}']")
    assert has_element?(view, "#shared-tree a[data-key='page:#{c.page.id}']")
  end

  test "opening a page that is no longer shared goes back to the Shared view", c do
    {:ok, grant} = Access.grant(c.page, c.sharee, "read", c.owner)
    {:ok, _} = Access.revoke(grant)

    assert {:error, {:live_redirect, %{to: "/shared"}}} =
             live(c.sharee_conn, ~p"/shared/pages/#{c.page.id}")
  end

  describe "with only a page grant, the sharee never sees" do
    setup c do
      {:ok, _} = Access.grant(c.page, c.sharee, "read", c.owner)
      :ok
    end

    test "the board's name, its cards or its other pages, in any HTML", c do
      {:ok, _v, shared_html} = live(c.sharee_conn, ~p"/shared")
      {:ok, view, page_html} = live(c.sharee_conn, ~p"/shared/pages/#{c.page.id}")
      {:ok, _v, wiki_html} = live(c.sharee_conn, ~p"/wiki")

      for html <- [shared_html, page_html, render(view), wiki_html] do
        refute html =~ "Secret Board Name"
        refute html =~ "Hidden folder name"
        refute html =~ "Sibling secret"
        refute html =~ "Confidential card title"
        refute html =~ "/boards/#{c.board.id}"
      end

      # The link to the page they can't see says so, and names nothing.
      assert page_html =~ "a page you can&#39;t see"
    end

    test "nor in the JSON of the page", c do
      {:ok, _} =
        Slipdock.Wiki.Placements.add(c.page, Wiki.get_folder(c.sibling.folder_id), c.owner)

      body =
        c.sharee_conn
        |> put_req_header("accept", "application/json")
        |> get("/api/pages/#{c.page.id}")
        |> response(200)

      refute body =~ "Secret Board Name"
      refute body =~ "Hidden folder name"
      refute body =~ "Sibling secret"
      refute body =~ "Confidential card title"
      refute body =~ c.board.code

      rendered =
        c.sharee_conn
        |> put_req_header("accept", "application/json")
        |> get("/api/pages/#{c.page.id}/render")
        |> response(200)

      refute rendered =~ "Confidential card title"
      refute rendered =~ "Secret Board Name"
    end

    test "nor can they open the board's own wiki", c do
      assert {:error, {:live_redirect, _}} = live(c.sharee_conn, ~p"/boards/#{c.board}/wiki")
      assert Boards.get_board!(c.board.id)
    end
  end

  test "a sharee's own wiki tree has a Shared with me section, kept live", c do
    own = board_fixture(%{"name" => "My own"}, owner: c.sharee)
    {:ok, view, _html} = live(c.sharee_conn, ~p"/boards/#{own}/wiki")
    refute has_element?(view, "#wiki-shared-tree")

    {:ok, grant} = Access.grant(c.shared, c.sharee, "read", c.owner)
    assert has_element?(view, "#wiki-shared-tree a[data-key='page:#{c.page.id}']")
    assert has_element?(view, "#wiki-shared-tree", "From")

    {:ok, _} = Access.revoke(grant)
    refute has_element?(view, "#wiki-shared-tree")
  end

  test "[[!children]] lists only the children the reader can read", c do
    {:ok, _} = Access.grant(c.page, c.sharee, "read", c.owner)

    attrs = %{
      "title" => "Child elsewhere",
      "parent_id" => c.page.id,
      "folder_id" => c.sibling.folder_id
    }

    page_fixture(c.board, attrs, user: c.owner)

    html =
      SlipdockWeb.Wiki.Renderer.to_html("[[!children]]", page: c.page, as: c.sharee, shared: true)

    refute html =~ "Child elsewhere"

    owner_html = SlipdockWeb.Wiki.Renderer.to_html("[[!children]]", page: c.page, as: c.owner)
    assert owner_html =~ "Child elsewhere"
  end

  describe "Also file in… (#818)" do
    setup c do
      mine = board_fixture(%{"name" => "Sharee board"}, owner: c.sharee)
      {:ok, inbox} = Wiki.create_folder(mine, %{"name" => "Inbox"})
      {:ok, _} = Access.grant(c.page, c.sharee, "read", c.owner)
      %{mine: mine, inbox: inbox}
    end

    test "files a shared page in a folder of the sharee's own", c do
      {:ok, view, _html} = live(c.sharee_conn, ~p"/shared/pages/#{c.page.id}")
      view |> element("#shared-also") |> render_click()
      assert has_element?(view, "#shared-also-form option", "Sharee board · Inbox")

      view |> form("#shared-also-form", %{folder: c.inbox.id}) |> render_submit()
      assert [%{id: id}] = Slipdock.Wiki.Placements.folders(c.page)
      assert id == c.inbox.id
    end

    test "the also-row shows in the sharee's own tree, opens in the Shared view, and can come out",
         c do
      {:ok, _} = Slipdock.Wiki.Placements.add(c.page, c.inbox, c.sharee)
      {:ok, view, _html} = live(c.sharee_conn, ~p"/boards/#{c.mine}/wiki")

      reply = SlipdockWeb.WikiTreeHelpers.tree_load(view, %{"keys" => ["folder:#{c.inbox.id}"]})
      row = SlipdockWeb.WikiTreeHelpers.row(reply, "folder:#{c.inbox.id}", "Shared plan")
      assert row.also
      assert row.href == "/shared/pages/#{c.page.id}"
      assert row.writable

      render_click(view, "remove_placement", %{
        "kind" => "page",
        "id" => to_string(c.page.id),
        "folder" => to_string(c.inbox.id)
      })

      assert Slipdock.Wiki.Placements.folders(c.page) == []
      assert Access.page_permission(c.sharee, c.page) == :read
    end
  end
end
