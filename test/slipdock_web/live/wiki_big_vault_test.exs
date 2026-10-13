defmodule SlipdockWeb.WikiBigVaultTest do
  @moduledoc """
  The wiki with a vault's worth of pages in it: a burst of changes (an import,
  a sync) reloads an open tab once rather than once a page; the tree loads
  each page cut to what it draws; and the wanted pages load who links, not
  the whole of every linking page.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures
  import Ecto.Query

  alias Slipdock.Wiki

  setup %{user: user} do
    %{board: board_fixture(%{"name" => "Vault", "code" => "vault"}, owner: user)}
  end

  # How many queries of the pages table `pid` makes while `fun` runs and
  # `settle` ms after: what one reload of the tree costs, counted.
  defp page_queries(pid, settle, fun), do: queries(pid, settle, fun, fn _ -> true end)

  # Only the tree's own query: the listing is the one that cuts bodies short.
  defp tree_loads(pid, settle, fun),
    do: queries(pid, settle, fun, &String.contains?(&1, "substr("))

  defp queries(pid, settle, fun, keep?) do
    test = self()
    id = "wiki-queries-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      id,
      [:slipdock, :repo, :query],
      fn _event, _measure, meta, _ ->
        if self() == pid and meta.source == "pages" and keep?.(meta.query),
          do: send(test, {:page_query, id})
      end,
      nil
    )

    try do
      fun.()
      Process.sleep(settle)
      count(id, 0)
    after
      :telemetry.detach(id)
    end
  end

  defp count(id, n) do
    receive do
      {:page_query, ^id} -> count(id, n + 1)
    after
      0 -> n
    end
  end

  describe "a burst of changes" do
    test "reloads an open tab once, not once a change", %{conn: conn, board: board} do
      page_fixture(board, %{"title" => "Already here"})
      {:ok, view, _html} = live(conn, ~p"/boards/#{board}/wiki")

      one = page_queries(view.pid, 500, fn -> send(view.pid, {:wiki_changed, board.id}) end)

      twenty =
        page_queries(view.pid, 500, fn ->
          for _ <- 1..20, do: send(view.pid, {:wiki_changed, board.id})
        end)

      assert one > 0
      assert twenty == one
    end

    test "still shows what the burst wrote, once it is over", %{
      conn: conn,
      board: board,
      user: user
    } do
      {:ok, view, _html} = live(conn, ~p"/boards/#{board}/wiki")

      for n <- 1..5 do
        {:ok, _} = Wiki.create_page(board, %{"title" => "Imported #{n}"}, user: user)
      end

      Process.sleep(500)
      html = render(view)
      for n <- 1..5, do: assert(html =~ "Imported #{n}")
    end

    test "after a reload, the next change books another", %{conn: conn, board: board, user: user} do
      {:ok, view, _html} = live(conn, ~p"/boards/#{board}/wiki")

      {:ok, _} = Wiki.create_page(board, %{"title" => "First"}, user: user)
      Process.sleep(500)
      assert render(view) =~ "First"

      {:ok, _} = Wiki.create_page(board, %{"title" => "Second"}, user: user)
      Process.sleep(500)
      assert render(view) =~ "Second"
    end
  end

  describe "opening a page from inside the wiki" do
    test "happens in place: same view, the tree left as it was", %{conn: conn, board: board} do
      one = page_fixture(board, %{"title" => "One", "body" => "first page"})
      two = page_fixture(board, %{"title" => "Two", "body" => "second page"})

      {:ok, view, _html} = live(conn, ~p"/boards/#{board}/wiki/#{one.slug}")
      pid = view.pid

      # The hook draws the rows with patch links (see assets/js/wiki_tree.js).
      reply = SlipdockWeb.WikiTreeHelpers.tree_load(view)
      assert %{nav: "patch", href: href} = SlipdockWeb.WikiTreeHelpers.row(reply, "root", "Two")
      assert href == "/boards/#{board.id}/wiki/#{two.slug}"

      version = tree_version(view)
      render_patch(view, href)

      assert view.pid == pid
      assert render(view) =~ "second page"
      assert has_element?(view, "#wiki-main[data-page='show:#{two.id}']")
      assert has_element?(view, "#wiki-tree[data-current='page:#{two.id}']")
      # Opening a page does not ask the tree for its rows again…
      assert tree_version(view) == version

      # …and a change to the wiki does, once.
      send(pid, {:wiki_changed, board.id})
      Process.sleep(500)
      assert tree_version(view) == version + 1
    end
  end

  defp tree_version(view) do
    [_, v] = Regex.run(~r/data-version="(\d+)"/, view |> element("#wiki-tree") |> render())
    String.to_integer(v)
  end

  describe "editing" do
    test "edit, save and back to the page never reload the tree", %{conn: conn, board: board} do
      page = page_fixture(board, %{"title" => "Notes", "body" => "before"})
      {:ok, view, _html} = live(conn, ~p"/boards/#{board}/wiki/#{page.slug}")
      pid = view.pid

      assert tree_loads(pid, 50, fn ->
               view |> element("a[href$='/wiki/#{page.slug}/edit']") |> render_click()
             end) == 0

      assert_patch(view, ~p"/boards/#{board}/wiki/#{page.slug}/edit")

      assert tree_loads(pid, 50, fn ->
               view |> form("#page-form", page: %{body: "after"}) |> render_submit()
             end) == 0

      assert_patch(view, ~p"/boards/#{board}/wiki/#{page.slug}")
      assert view.pid == pid
      assert render(view) =~ "after"

      # The save's own change reaches the tree once, in its own time.
      Process.sleep(500)
      assert render(view) =~ "Notes"
    end
  end

  describe "list_pages(listing: true)" do
    test "cuts the body to what an excerpt needs and leaves the front matter", %{board: board} do
      page = page_fixture(board, %{"title" => "Long", "body" => String.duplicate("word ", 1000)})

      Slipdock.Repo.update_all(
        from(p in Slipdock.Wiki.Page, where: p.id == ^page.id),
        set: [front_matter: "type: note"]
      )

      assert Wiki.get_page(page.id).front_matter == "type: note"

      [listed] = Wiki.list_pages(board, listing: true)
      assert listed.id == page.id
      assert listed.title == "Long"
      assert listed.slug == page.slug
      assert String.length(listed.body) == 1000
      assert String.starts_with?(Wiki.get_page(page.id).body, listed.body)
      assert listed.front_matter == nil

      [whole] = Wiki.list_pages(board)
      assert whole.body == Wiki.get_page(page.id).body
    end

    test "a short body comes whole, and filters still apply", %{board: board} do
      page_fixture(board, %{"title" => "Short", "body" => "tiny"})
      page_fixture(board, %{"title" => "Draft", "status" => "draft"})

      assert [%{title: "Short", body: "tiny"}] =
               Wiki.list_pages(board, listing: true, status: "published")
    end

    test "the index still shows a page's excerpt from it", %{conn: conn, board: board} do
      page_fixture(board, %{"title" => "Excerpted", "body" => "The opening line of the note."})
      {:ok, view, _html} = live(conn, ~p"/boards/#{board}/wiki")
      assert render(view) =~ "The opening line of the note."
    end
  end

  describe "wanted" do
    test "names who links without loading the whole linking page", %{board: board, user: user} do
      {:ok, _} =
        Wiki.create_page(
          board,
          %{"title" => "Runbook", "body" => "see [[Rollback]]\n" <> String.duplicate("x", 5000)},
          user: user
        )

      assert [%{title: "Rollback", from: [from]}] = Wiki.wanted(board)
      assert from.title == "Runbook"
      assert from.slug
      assert from.body == ""
    end

    test "is shown on the index, and not worked out with a page open",
         %{conn: conn, board: board, user: user} do
      {:ok, runbook} =
        Wiki.create_page(board, %{"title" => "Runbook", "body" => "see [[Rollback]]"}, user: user)

      {:ok, view, _html} = live(conn, ~p"/boards/#{board}/wiki")
      assert render(view) =~ "Wanted pages"

      {:ok, view, _html} = live(conn, ~p"/boards/#{board}/wiki/#{runbook.slug}")
      refute render(view) =~ "Wanted pages"
      assert :sys.get_state(view.pid).socket.assigns.wanted == []
    end
  end
end
