defmodule SlipdockWeb.MultiboardLiveTest do
  @moduledoc """
  The Multiboard page (#1479): reached from the home page, lists picked from
  several boards, the top N of each shown by board, by list or as a grid,
  and the view kept in the URL and on the account.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Multiboard, Repo}
  alias Slipdock.Multiboard.Saved

  setup %{user: user} do
    ops = board_fixture(%{"name" => "Ops"}, owner: user)
    web = board_fixture(%{"name" => "Web"}, owner: user)
    [_, ops_todo, ops_doing, _] = ops.columns
    [_, web_todo, _, _] = web.columns

    for t <- ["Fix the pager", "Rotate keys", "Third ops card"],
        do: card_fixture(ops_todo, %{"title" => t})

    card_fixture(ops_doing, %{"title" => "Deploying"})
    card_fixture(web_todo, %{"title" => "New landing page"})
    %{ops: ops, web: web, ops_todo: ops_todo, ops_doing: ops_doing, web_todo: web_todo}
  end

  defp mb_path(lists, extra \\ []),
    do: ~p"/multiboard?#{[lists: Enum.map_join(lists, ",", & &1.id)] ++ extra}"

  test "the home page links to it", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/")
    assert has_element?(view, "#open-multiboard[href='/multiboard']")
  end

  test "with nothing chosen, the picker is open and offers every board's lists",
       %{conn: conn} = ctx do
    {:ok, view, html} = live(conn, ~p"/multiboard")
    assert html =~ "Pick lists from any of your boards"
    assert has_element?(view, "#multiboard-picker")
    assert has_element?(view, "#multiboard-pick-#{ctx.ops_todo.id}")
    assert has_element?(view, "#multiboard-pick-#{ctx.web_todo.id}")
  end

  test "ticking lists shows their top cards, and remembers the view",
       %{conn: conn, user: user} = ctx do
    {:ok, view, _} = live(conn, ~p"/multiboard")

    view
    |> form("#multiboard-picker")
    |> render_change(%{"lists" => ["", "#{ctx.ops_todo.id}", "#{ctx.web_todo.id}"], "top" => "2"})

    path = assert_patch(view)
    assert path =~ "top=2"
    html = render(view)
    assert html =~ "Fix the pager"
    assert html =~ "Rotate keys"
    refute html =~ "Third ops card"
    assert html =~ "New landing page"
    refute html =~ "Deploying"
    assert html =~ "The top 2 of 2 lists across 2 boards."

    assert Multiboard.prefs(Repo.reload(user)) ==
             %{lists: [ctx.ops_todo.id, ctx.web_todo.id], top: 2, by: "board"}

    # A bare /multiboard opens the remembered view.
    {:ok, again, _} = live(conn, ~p"/multiboard")
    refute has_element?(again, "#multiboard-picker")
    assert render(again) =~ "Rotate keys"
  end

  test "by board: a section per board, each row naming its list", %{conn: conn} = ctx do
    {:ok, view, _} = live(conn, mb_path([ctx.ops_todo, ctx.ops_doing, ctx.web_todo]))
    assert has_element?(view, "#multiboard-board-#{ctx.ops.id}", "Deploying")
    assert has_element?(view, "#multiboard-board-#{ctx.ops.id}", "In Progress")
    assert has_element?(view, "#multiboard-board-#{ctx.web.id}", "New landing page")
    assert has_element?(view, "#multiboard-by-board[aria-pressed=true]")
  end

  test "by list and grid lay the same cards out differently", %{conn: conn} = ctx do
    {:ok, view, _} = live(conn, mb_path([ctx.ops_todo, ctx.ops_doing]))

    view |> element("#multiboard-by-list") |> render_click()
    assert assert_patch(view) =~ "by=list"
    assert has_element?(view, "#multiboard-list-#{ctx.ops_doing.id}", "Ops › In Progress")
    assert has_element?(view, "#multiboard-list-#{ctx.ops_todo.id}", "Fix the pager")

    view |> element("#multiboard-by-grid") |> render_click()
    assert assert_patch(view) =~ "by=grid"
    assert has_element?(view, "#multiboard-grid a", "Deploying")
    assert has_element?(view, "#multiboard-grid", "Ops › To Do")
    refute has_element?(view, "#multiboard-board-#{ctx.ops.id}")
  end

  test "a card links to itself on its board", %{conn: conn} = ctx do
    card = card_fixture(ctx.web_todo, %{"title" => "Linked card"})
    {:ok, view, _} = live(conn, mb_path([ctx.web_todo]))
    assert has_element?(view, "a[href='/boards/#{ctx.web.id}/cards/#{card.id}']", "Linked card")
  end

  test "an empty list says so; Clear all empties the view", %{conn: conn} = ctx do
    [_, _, _, ops_done] = ctx.ops.columns
    {:ok, view, _} = live(conn, mb_path([ops_done, ctx.ops_todo]))
    assert has_element?(view, "#multiboard-board-#{ctx.ops.id}", "Fix the pager")

    {:ok, view, _} = live(conn, mb_path([ops_done], by: "list"))
    assert has_element?(view, "#multiboard-list-#{ops_done.id}", "No cards.")

    view |> element("#multiboard-choose") |> render_click()
    view |> element("#multiboard-picker button", "Clear all") |> render_click()
    assert_patch(view)
    assert render(view) =~ "Pick lists from any of your boards"
  end

  test "another person's lists in the URL show nothing of theirs", %{conn: conn} = ctx do
    stranger = user_fixture("stranger@example.com")
    theirs = board_fixture(%{"name" => "Theirs"}, owner: stranger)
    [_, their_todo | _] = theirs.columns
    card_fixture(their_todo, %{"title" => "Their secret"})

    {:ok, view, html} = live(conn, mb_path([their_todo, ctx.web_todo]))
    refute html =~ "Their secret"
    refute html =~ "Theirs"
    assert render(view) =~ "New landing page"
  end

  test "a card added on a board shows up without a reload", %{conn: conn} = ctx do
    {:ok, view, _} = live(conn, mb_path([ctx.ops_doing]))
    card_fixture(ctx.ops_doing, %{"title" => "Arrived later"})
    send(view.pid, {:boards_changed})
    assert render(view) =~ "Arrived later"
  end

  describe "saving a view (#1482)" do
    defp saved(user, name, lists, color \\ "indigo") do
      {:ok, saved} =
        Multiboard.create_saved(user, %{"name" => name, "color" => color}, %{
          lists: Enum.map(lists, & &1.id),
          top: 5,
          by: "board"
        })

      saved
    end

    test "Save names the view with a colour, and opens it at its own address",
         %{conn: conn, user: user} = ctx do
      {:ok, view, _} = live(conn, mb_path([ctx.ops_todo], top: 2))

      view |> element("#multiboard-save") |> render_click()
      assert has_element?(view, "#multiboard-save-form")
      view |> element("#multiboard-save-color-rose") |> render_click()
      assert has_element?(view, "#multiboard-save-color-rose[aria-pressed=true]")

      view |> form("#multiboard-save-form", %{"name" => " Ops queue "}) |> render_submit()

      [saved] = Multiboard.list_saved(user)
      assert {saved.name, saved.color} == {"Ops queue", "rose"}
      assert Saved.view(saved) == %{lists: [ctx.ops_todo.id], top: 2, by: "board"}

      assert assert_patch(view) == "/multiboard/#{saved.id}"
      assert has_element?(view, "#multiboard-title", "Ops queue")
      assert render(view) =~ "It is on your home page"
      refute has_element?(view, "#multiboard-save-form")
    end

    test "a blank name is refused and nothing is saved", %{conn: conn, user: user} = ctx do
      {:ok, view, _} = live(conn, mb_path([ctx.ops_todo]))
      view |> element("#multiboard-save") |> render_click()
      html = view |> form("#multiboard-save-form", %{"name" => "  "}) |> render_submit()

      assert html =~ "couldn&#39;t be saved"
      assert Multiboard.list_saved(user) == []
    end

    test "a saved one shows its view; changing it there changes the saved one, not the page's",
         %{conn: conn, user: user} = ctx do
      mb = saved(user, "Web only", [ctx.web_todo], "teal")
      before = Repo.reload(user).multiboard

      {:ok, view, html} = live(conn, ~p"/multiboard/#{mb.id}")
      assert html =~ "New landing page"
      refute html =~ "Fix the pager"
      assert has_element?(view, "#multiboard-title", "Web only")

      view |> element("#multiboard-choose") |> render_click()

      view
      |> form("#multiboard-picker")
      |> render_change(%{"lists" => ["", "#{ctx.ops_todo.id}"], "top" => "1"})

      assert assert_patch(view) =~ "/multiboard/#{mb.id}?"
      assert render(view) =~ "Fix the pager"
      assert Saved.view(Repo.reload(mb)) == %{lists: [ctx.ops_todo.id], top: 1, by: "board"}
      assert Repo.reload(user).multiboard == before

      view |> element("#multiboard-by-grid") |> render_click()
      assert_patch(view)
      assert Repo.reload(mb).by == "grid"
    end

    test "Rename changes its name and colour", %{conn: conn, user: user} = ctx do
      mb = saved(user, "Old", [ctx.ops_todo], "teal")
      {:ok, view, _} = live(conn, ~p"/multiboard/#{mb.id}")

      view |> element("#multiboard-save", "Rename") |> render_click()
      assert has_element?(view, "#multiboard-save-color-teal[aria-pressed=true]")
      view |> element("#multiboard-save-color-amber") |> render_click()
      view |> form("#multiboard-save-form", %{"name" => "New"}) |> render_submit()

      assert %{name: "New", color: "amber"} = Repo.reload(mb)
      assert Multiboard.list_saved(user) |> length() == 1
    end

    test "Delete removes it and goes back to the plain page", %{conn: conn, user: user} = ctx do
      mb = saved(user, "Doomed", [ctx.ops_todo])
      {:ok, view, _} = live(conn, ~p"/multiboard/#{mb.id}")

      view |> element("#multiboard-delete") |> render_click()
      assert_redirect(view, ~p"/multiboard")
      assert Multiboard.list_saved(user) == []
    end

    test "somebody else's, or one gone, sends you to the plain page", %{conn: conn} = ctx do
      stranger = user_fixture("mb-saved-stranger@example.com")
      theirs = saved(stranger, "Theirs", [ctx.ops_todo])

      assert {:error, {:live_redirect, %{to: "/multiboard", flash: flash}}} =
               live(conn, ~p"/multiboard/#{theirs.id}")

      assert flash["error"] =~ "isn't one of yours"
      assert {:error, {:live_redirect, %{to: "/multiboard"}}} = live(conn, ~p"/multiboard/0")
    end
  end
end
