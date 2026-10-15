defmodule SlipdockWeb.WikiShareLiveTest do
  @moduledoc "Sharing a wiki page from the wiki itself (#814)."
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import SlipdockWeb.WikiTreeHelpers
  import Slipdock.Fixtures

  alias Slipdock.{Access, Accounts}

  setup %{user: user} do
    board = board_fixture(%{"name" => "Handbook"}, owner: user)
    page = page_fixture(board, %{"title" => "Retry policy", "body" => "Three times."})
    %{board: board, page: page}
  end

  defp open_share(view, page) do
    view |> element("#share-page") |> render_click()
    assert has_element?(view, "#share-modal")
    _ = page
    view
  end

  defp share(view, params) do
    view
    |> form("#share-modal form[phx-submit=share]", params)
    |> render_submit()
  end

  test "the owner shares a page with a person, changes the level and takes it back", %{
    conn: conn,
    board: board,
    page: page
  } do
    friend = user_fixture("friend@example.com")
    {:ok, view, _html} = live(conn, ~p"/boards/#{board}/wiki/#{page.slug}")

    refute has_element?(view, "#page-shared")
    open_share(view, page)
    share(view, %{"email" => friend.email, "level" => "read"})

    assert [grant] = Access.list_grants(page)
    assert grant.user_id == friend.id and grant.level == "read"
    assert has_element?(view, "#grant-page-#{grant.id}", "read only")
    assert Access.page_permission(friend, page) == :read
    # The page now says it is shared.
    assert has_element?(view, "#page-shared", "Shared with 1 person or group")

    # Sharing again with the same person changes the level, not the count.
    share(view, %{"email" => friend.email, "level" => "write"})
    assert [%{level: "write"} = grant] = Access.list_grants(page)
    assert has_element?(view, "#grant-page-#{grant.id}", "can edit")
    assert Access.page_permission(friend, page) == :write

    view |> element("#grant-page-#{grant.id} button[phx-click=revoke_grant]") |> render_click()
    assert Access.list_grants(page) == []
    assert Access.page_permission(friend, page) == :none
    refute has_element?(view, "#grant-page-#{grant.id}")
    refute has_element?(view, "#page-shared")
  end

  test "a page can be shared with a group the reader has", %{
    conn: conn,
    board: board,
    page: page,
    user: user
  } do
    member = user_fixture("member@example.com")
    {:ok, group} = Accounts.create_group(user, %{"name" => "Ops"})
    {:ok, _} = Accounts.add_group_member(group, member.email)

    {:ok, view, _html} = live(conn, ~p"/boards/#{board}/wiki/#{page.slug}")
    open_share(view, page)
    share(view, %{"group" => to_string(group.id), "email" => "", "level" => "write"})

    assert [grant] = Access.list_grants(page)
    assert grant.group_id == group.id
    assert Access.page_permission(member, page) == :write
  end

  test "an empty address is refused with a reason", %{conn: conn, board: board, page: page} do
    {:ok, view, _html} = live(conn, ~p"/boards/#{board}/wiki/#{page.slug}")
    open_share(view, page)
    html = share(view, %{"email" => "  ", "level" => "read"})

    assert html =~ "Enter an email address or pick a group."
    assert Access.list_grants(page) == []
  end

  test "the tree marks a shared page and offers Share… to a writer", %{
    conn: conn,
    board: board,
    page: page
  } do
    other = page_fixture(board, %{"title" => "Runbook"})
    friend = user_fixture("friend@example.com")
    {:ok, _} = Access.grant(page, friend, "read", board_owner(board))

    {:ok, view, _html} = live(conn, ~p"/boards/#{board}/wiki")
    reply = tree_load(view)

    assert row(reply, "root", "Retry policy")[:shared]
    assert row(reply, "root", "Retry policy")[:shareable]
    refute row(reply, "root", "Runbook")[:shared]
    assert row(reply, "root", "Runbook")[:shareable]
    assert other
  end

  test "a folder is shared from the tree's folder menu, and wears the mark (#815)", %{
    conn: conn,
    board: board
  } do
    {:ok, folder} = Slipdock.Wiki.create_folder(board, %{"name" => "Specs"})
    inside = page_fixture(board, %{"title" => "Inside", "folder_id" => folder.id})
    friend = user_fixture("friend@example.com")

    {:ok, view, _html} = live(conn, ~p"/boards/#{board}/wiki")
    assert row(tree_load(view), "root", "Specs")[:shareable]
    refute row(tree_load(view), "root", "Specs")[:shared]

    render_click(view, "share_item", %{"kind" => "folder", "id" => to_string(folder.id)})
    assert has_element?(view, "#share-modal", "Share “Specs”")
    assert render(view) =~ "Sharing a folder shares everything in it"
    share(view, %{"email" => friend.email, "level" => "write"})

    assert [%{folder_id: id, level: "write"}] = Access.list_grants(folder)
    assert id == folder.id
    assert Access.page_permission(friend, inside) == :write
    assert row(tree_load(view), "root", "Specs")[:shared]
  end

  describe "somebody the page was shared with" do
    setup %{board: board, page: page, user: owner} do
      sharee = user_fixture("sharee@example.com")
      # A reader of the board, raised to a writer on this one page.
      {:ok, _} = Access.grant(board, sharee, "read", owner)
      {:ok, _} = Access.grant(page, sharee, "write", owner)
      %{sharee: sharee, sharee_conn: log_in_user(build_conn(), sharee)}
    end

    test "sees no Share item, in the page menu or the tree", %{
      sharee_conn: conn,
      board: board,
      page: page
    } do
      {:ok, view, _html} = live(conn, ~p"/boards/#{board}/wiki/#{page.slug}")

      refute has_element?(view, "#share-page")
      reply = tree_load(view)
      refute row(reply, "root", "Retry policy")[:shareable]
    end

    test "is refused when sending the events anyway", %{
      sharee_conn: conn,
      board: board,
      page: page,
      sharee: sharee
    } do
      stranger = user_fixture("stranger@example.com")
      {:ok, view, _html} = live(conn, ~p"/boards/#{board}/wiki/#{page.slug}")

      html = render_click(view, "share_item", %{"kind" => "page", "id" => to_string(page.id)})
      assert html =~ "You can&#39;t share that."
      refute has_element?(view, "#share-modal")

      html =
        render_click(view, "share", %{
          "resource" => "page",
          "email" => stranger.email,
          "level" => "write"
        })

      assert html =~ "You can&#39;t share that."
      assert Access.page_permission(stranger, page) == :none
      assert [_] = Enum.filter(Access.list_grants(page), &(&1.user_id == sharee.id))

      [grant] = Access.list_grants(page)
      render_click(view, "revoke_grant", %{"id" => to_string(grant.id), "resource" => "page"})
      assert [_] = Access.list_grants(page)
    end
  end

  defp board_owner(board), do: Slipdock.Repo.get!(Accounts.User, board.owner_id)
end
