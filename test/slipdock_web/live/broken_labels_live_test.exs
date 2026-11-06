defmodule SlipdockWeb.BrokenLabelsLiveTest do
  @moduledoc """
  Labels and numbers that said something untrue (#1698, design review
  W-2303): switches that said "is on" when off, a wiki home counting none
  of the pages beside it, raw ISO times, "0s" for a cycle time nobody has
  had, "80 %", and a history counted in bytes.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures
  import SlipdockWeb.RelativeTimeHelpers

  alias Slipdock.{Accounts, Boards, Repo, Settings, Wiki}
  alias Slipdock.Wiki.KnowledgeBase
  alias SlipdockWeb.UsersLive.Index, as: UsersIndex

  defp as_admin(conn) do
    {:ok, _} =
      Settings.complete_setup(%{"admin_email" => "admin@example.com", "signup_mode" => :closed})

    {:ok, admin} = Accounts.promote(user_fixture("admin@example.com"))
    {log_in_user(conn, admin), admin}
  end

  describe "the wiki home's page count" do
    setup %{user: user} do
      {:ok, kb} = KnowledgeBase.ensure(user)
      alpha = board_fixture(%{"name" => "Alpha", "code" => "bl1698a"}, owner: user)
      beta = board_fixture(%{"name" => "Beta", "code" => "bl1698b"}, owner: user)
      %{kb: kb, alpha: alpha, beta: beta}
    end

    test "counts the pages of every board in the tree, not the Knowledge Base's alone", %{
      conn: conn,
      user: user,
      alpha: alpha,
      beta: beta
    } do
      page_fixture(alpha, %{"title" => "One"}, user: user)
      page_fixture(alpha, %{"title" => "Two"}, user: user)
      page_fixture(beta, %{"title" => "Three"}, user: user)

      {:ok, view, _} = live(conn, ~p"/wiki")

      assert has_element?(view, "#tree-page-count", "3 pages")
      refute has_element?(view, "#tree-page-count", "0 pages")
    end

    test "counts the Knowledge Base's own pages with the boards'", %{
      conn: conn,
      user: user,
      kb: kb,
      alpha: alpha
    } do
      page_fixture(kb, %{"title" => "Home note"}, user: user)
      page_fixture(alpha, %{"title" => "Board note"}, user: user)

      {:ok, view, _} = live(conn, ~p"/wiki")
      assert has_element?(view, "#tree-page-count", "2 pages")
    end

    test "one page is one page", %{conn: conn, user: user, beta: beta} do
      page_fixture(beta, %{"title" => "Only"}, user: user)

      {:ok, view, _} = live(conn, ~p"/wiki")
      assert has_element?(view, "#tree-page-count", "1 page")
      refute has_element?(view, "#tree-page-count", "1 pages")
    end

    test "a board's own wiki still counts that board's pages", %{
      conn: conn,
      user: user,
      alpha: alpha,
      beta: beta
    } do
      page_fixture(alpha, %{"title" => "Mine"}, user: user)
      page_fixture(beta, %{"title" => "Not mine"}, user: user)
      page_fixture(beta, %{"title" => "Not mine either"}, user: user)

      {:ok, view, _} = live(conn, ~p"/boards/#{alpha}/wiki")
      assert has_element?(view, "#tree-page-count", "1 page")
    end

    test "a board that isn't readable is not counted", %{conn: conn, user: user, alpha: alpha} do
      page_fixture(alpha, %{"title" => "Mine"}, user: user)
      stranger = user_fixture("bl1698.stranger@example.com")
      theirs = board_fixture(%{"name" => "Theirs", "code" => "bl1698c"}, owner: stranger)
      page_fixture(theirs, %{"title" => "Private"}, user: stranger)

      {:ok, view, _} = live(conn, ~p"/wiki")
      assert has_element?(view, "#tree-page-count", "1 page")
    end
  end

  describe "Users → Last seen" do
    test "is relative, never an ISO timestamp, and 'never' for nobody", %{conn: conn} do
      {conn, _admin} = as_admin(conn)
      recent = user_fixture("bl1698.recent@example.com")
      never = user_fixture("bl1698.never@example.com")

      at = DateTime.utc_now() |> DateTime.add(-5 * 60) |> DateTime.truncate(:second)
      Repo.update!(Ecto.Changeset.change(recent, last_signed_in_at: at))
      Repo.update!(Ecto.Changeset.change(never, last_signed_in_at: nil))

      {{:ok, view, html}, before, later} = rendered_around(fn -> live(conn, ~p"/users") end)

      assert Enum.any?(
               expected_labels(at, "5 min ago", before, later),
               &has_element?(view, "#last-seen-#{recent.id}", &1)
             )

      assert has_element?(view, "#last-seen-#{recent.id}[datetime='#{DateTime.to_iso8601(at)}']")
      refute has_element?(view, "#last-seen-#{never.id}")
      refute html =~ ~r/>\s*\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ\s*</
    end

    test "past a week it is the date, with the year once it isn't this one" do
      now = ~U[2026-11-04 12:00:00Z]

      assert UsersIndex.last_seen(~U[2026-10-01 09:30:00Z], now) == "1 Oct"
      assert UsersIndex.last_seen(~U[2025-12-24 09:30:00Z], now) == "24 Dec 2025"
    end

    test "within the week it is relative" do
      at = DateTime.add(DateTime.utc_now(), -3 * 86_400)
      assert UsersIndex.last_seen(at) == "3 days ago"
      assert UsersIndex.last_seen(DateTime.utc_now()) == "just now"
    end
  end

  describe "Visualise cycle time" do
    test "shows — and says why when no card has finished", %{conn: conn, user: user} do
      board = board_fixture(%{"name" => "Fresh", "code" => "bl1698v"}, owner: user)
      card_fixture(hd(board.columns), %{"title" => "Still going"})

      {:ok, view, _} = live(conn, ~p"/boards/#{board}/visualise")

      assert has_element?(view, "#tile-cycle [data-value]", "—")
      assert has_element?(view, "#tile-cycle", "not enough data yet")
      refute has_element?(view, "#tile-cycle [data-value]", "0s")
    end

    test "shows the time once a card has finished", %{conn: conn, user: user} do
      board = board_fixture(%{"name" => "Moving", "code" => "bl1698w"}, owner: user)
      card = card_fixture(hd(board.columns), %{"title" => "Finished"})
      {:ok, _} = Boards.update_card(card, %{"completed" => true})

      {:ok, view, _} = live(conn, ~p"/boards/#{board}/visualise")

      refute has_element?(view, "#tile-cycle", "not enough data yet")
      assert has_element?(view, "#tile-cycle", "1 card (90 days)")
    end
  end

  describe "wiki history" do
    setup %{user: user} do
      board = board_fixture(%{"name" => "History", "code" => "bl1698h"}, owner: user)
      %{board: board}
    end

    test "says lines added and removed for each version, never bytes", %{
      conn: conn,
      user: user,
      board: board
    } do
      page = page_fixture(board, %{"title" => "Doc", "body" => "one\ntwo\nthree\n"}, user: user)
      # Each its own version: saves close together would fold into one.
      apart = [user: user, new_revision: true]
      {:ok, page} = Wiki.update_page(page, %{"body" => "one\n2\nthree\nfour\n"}, apart)
      {:ok, page} = Wiki.update_page(page, %{"title" => "Doc, renamed"}, apart)
      # Saved with nothing changed: no new version to list.
      {:ok, page} = Wiki.update_page(page, %{"body" => page.body}, apart)

      [renamed, edit, first] = Wiki.list_revisions(page)

      {:ok, view, html} = live(conn, ~p"/boards/#{board}/wiki/#{page.slug}/history")

      assert has_element?(view, "#revision-changes-#{first.id}", "+3 lines")
      assert has_element?(view, "#revision-changes-#{edit.id}", "+2 −1 lines")
      assert has_element?(view, "#revision-changes-#{renamed.id}", "title only")
      refute html =~ "bytes"
    end

    test "a page's first version with nothing in it changed nothing", %{
      conn: conn,
      user: user,
      board: board
    } do
      page = page_fixture(board, %{"title" => "Empty"}, user: user)
      [first] = Wiki.list_revisions(page)

      {:ok, view, _} = live(conn, ~p"/boards/#{board}/wiki/#{page.slug}/history")
      assert has_element?(view, "#revision-changes-#{first.id}", "no changes")
    end
  end
end
