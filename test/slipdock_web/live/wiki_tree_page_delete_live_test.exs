defmodule SlipdockWeb.WikiTreePageDeleteLiveTest do
  @moduledoc """
  Deleting a page for good from the wiki's tree (#1098): Delete… on its
  menu asks first, with the warning the page's own menu gives (how many
  pages under it are kept); only the board's owner may confirm, and a
  writer is told so; a reader is asked nothing.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures
  import SlipdockWeb.WikiTreeHelpers

  alias Slipdock.Wiki

  setup %{user: user} do
    kb = board_fixture(%{"name" => "KB", "code" => "kbpdel"}, owner: user)
    plan = page_fixture(kb, %{"title" => "Plan"}, user: user)
    %{kb: kb, plan: plan}
  end

  defp in_tree?(view, title),
    do: tree_load(view).nodes["root"] |> Enum.any?(&(&1.title == title))

  defp ask(view, page), do: render_hook(view, "ask_delete_page", %{"id" => to_string(page.id)})

  test "Delete asks, Cancel keeps it, Delete for good takes it and its history", ctx do
    %{conn: conn, kb: kb, plan: plan} = ctx
    {:ok, view, _} = live(conn, ~p"/boards/#{kb}/wiki")

    ask(view, plan)
    assert has_element?(view, "#tree-prompt h2", "Delete “Plan”?")
    assert has_element?(view, "#tree-delete-page-warning", "cannot be undone")
    refute has_element?(view, "#tree-delete-page-owner-only")
    view |> element("button[phx-click='close_tree_prompt']", "Cancel") |> render_click()
    assert Wiki.get_page(plan.id)

    ask(view, plan)

    assert view |> element("#tree-delete-page-confirm") |> render_click() =~
             "Deleted “Plan” for good."

    assert is_nil(Wiki.get_page(plan.id))
    refute has_element?(view, "#tree-prompt")
    refute in_tree?(view, "Plan")
  end

  test "the warning counts the pages under it, and they are kept at the top", ctx do
    %{conn: conn, kb: kb, plan: plan, user: user} = ctx
    child = page_fixture(kb, %{"title" => "Child", "parent_id" => plan.id}, user: user)
    {:ok, view, _} = live(conn, ~p"/boards/#{kb}/wiki")

    ask(view, plan)
    assert has_element?(view, "#tree-delete-page-warning", "The 1 page under it will be kept")

    view |> element("#tree-delete-page-confirm") |> render_click()
    assert %{parent_id: nil} = Wiki.get_page(child.id)
    assert in_tree?(view, "Child")
  end

  test "deleting the page being read goes back to the wiki; another stays put", ctx do
    %{conn: conn, kb: kb, plan: plan, user: user} = ctx
    other = page_fixture(kb, %{"title" => "Other"}, user: user)

    {:ok, view, _} = live(conn, ~p"/boards/#{kb}/wiki/#{other.slug}")
    ask(view, plan)
    view |> element("#tree-delete-page-confirm") |> render_click()
    assert has_element?(view, "h1", "Other")

    ask(view, other)
    view |> element("#tree-delete-page-confirm") |> render_click()
    assert_patch(view, ~p"/boards/#{kb}/wiki")
    assert is_nil(Wiki.get_page(other.id))
  end

  test "a writer who isn't the owner is told only the owner deletes, and refused", ctx do
    %{kb: kb, plan: plan, user: owner} = ctx
    writer = user_fixture("page-del-writer@example.com")
    {:ok, _} = Slipdock.Access.grant(kb, writer, "write", owner)
    {:ok, view, _} = live(log_in_user(build_conn(), writer), ~p"/boards/#{kb}/wiki")

    ask(view, plan)
    assert has_element?(view, "#tree-delete-page-owner-only")
    refute has_element?(view, "#tree-delete-page-confirm")

    # Sent anyway, the server still refuses.
    assert render_click(view, "delete_from_tree", %{}) =~
             "Only the board&#39;s owner can delete a page."

    assert Wiki.get_page(plan.id)
  end

  test "a reader is asked nothing, and a stray delete changes nothing", ctx do
    %{kb: kb, plan: plan, user: owner} = ctx
    reader = user_fixture("page-del-reader@example.com")
    {:ok, _} = Slipdock.Access.grant(kb, reader, "read", owner)
    {:ok, view, _} = live(log_in_user(build_conn(), reader), ~p"/boards/#{kb}/wiki")

    ask(view, plan)
    refute has_element?(view, "#tree-prompt")
    assert render_click(view, "delete_from_tree", %{}) =~ "That page couldn&#39;t be deleted."
    assert Wiki.get_page(plan.id)
  end

  test "a page already gone, or a nonsense id, asks nothing", ctx do
    %{conn: conn, kb: kb, plan: plan} = ctx
    {:ok, view, _} = live(conn, ~p"/boards/#{kb}/wiki")
    {:ok, _} = Wiki.delete_page(plan)

    ask(view, plan)
    render_hook(view, "ask_delete_page", %{"id" => "nonsense"})
    refute has_element?(view, "#tree-prompt")
  end

  test "deleted between asking and confirming, it says so and the prompt stays", ctx do
    %{conn: conn, kb: kb, plan: plan} = ctx
    {:ok, view, _} = live(conn, ~p"/boards/#{kb}/wiki")

    ask(view, plan)
    {:ok, _} = Wiki.delete_page(plan)

    assert view |> element("#tree-delete-page-confirm") |> render_click() =~
             "That page couldn&#39;t be deleted."
  end
end
