defmodule SlipdockWeb.PublicLiveTest do
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures
  alias Slipdock.Boards

  setup do
    board = board_fixture(%{"name" => "Roadmap"})
    [todo | _] = board.columns

    shown =
      card_fixture(todo, %{
        "title" => "Shown card",
        "start_date" => "2030-01-10",
        "due_date" => "2030-01-20"
      })

    gone = card_fixture(todo, %{"title" => "Archived card", "due_date" => "2030-01-21"})
    {:ok, _} = Boards.archive_card(gone)

    other = board_fixture(%{"name" => "Private elsewhere"})
    card_fixture(hd(other.columns), %{"title" => "Secret card"})

    %{board: reload(board), todo: todo, shown: shown, anon: Phoenix.ConnTest.build_conn()}
  end

  defp publish(board, name, config) do
    {:ok, view} = Boards.create_saved_view(board, %{"name" => name, "config" => config})
    {:ok, view} = Boards.publish_saved_view(view)
    view
  end

  describe "what a share shows" do
    test "the board through the view, and nothing more", %{board: board, anon: anon} do
      view = publish(board, "Public board", %{"mode" => "board"})

      {:ok, lv, html} = live(anon, ~p"/p/#{view.public_token}")

      assert html =~ "Roadmap"
      assert html =~ "Public board"
      assert html =~ "Published view"
      assert html =~ "Shown card"
      assert page_title(lv) =~ "Public board · Roadmap"

      refute html =~ "Archived card"
      refute html =~ "Secret card"
      refute html =~ "Private elsewhere"
      refute html =~ "Filtered"

      # Read-only: no view settings, no quick add, no way into a card.
      refute has_element?(lv, "#swim-config")
      refute has_element?(lv, "form[phx-submit=swim_quick_add]")
      refute has_element?(lv, "[phx-click=swim_start_add]")
      refute html =~ ~s(href="/boards/#{board.id})
    end

    test "a filtered view says so and keeps to its filter", %{
      board: board,
      todo: todo,
      anon: anon
    } do
      tag = tag_fixture(board, "launch")
      tagged = card_fixture(todo, %{"title" => "Tagged card"})
      {:ok, _} = Boards.toggle_card_tag(tagged, tag)

      view = publish(board, "Launch only", %{"mode" => "table", "tags" => [tag.id]})
      {:ok, _lv, html} = live(anon, ~p"/p/#{view.public_token}")

      assert html =~ "Filtered"
      assert html =~ "Tagged card"
      refute html =~ "Shown card"
    end

    test "a write a component might push changes nothing", %{
      board: board,
      shown: shown,
      anon: anon
    } do
      view = publish(board, "Public board", %{"mode" => "board"})
      {:ok, lv, _} = live(anon, ~p"/p/#{view.public_token}")
      [_, doing | _] = board.columns

      render_click(lv, "swim_move", %{"id" => to_string(shown.id), "column" => doing.id})
      render_click(lv, "swim_quick_add", %{"title" => "Sneaked in"})

      card = Boards.get_card!(shown.id)
      assert card.column_id == shown.column_id
      refute render(lv) =~ "Sneaked in"

      refute Enum.any?(reload(board).columns, fn c ->
               Enum.any?(c.cards, &(&1.title == "Sneaked in"))
             end)
    end
  end

  describe "links that do not lead anywhere" do
    test "an unknown token goes to the login page", %{anon: anon} do
      assert {:error, {:redirect, %{to: "/login", flash: flash}}} = live(anon, ~p"/p/nonsense")
      assert flash["error"] =~ "no longer published"
    end

    test "a revoked link stops working", %{board: board, anon: anon} do
      view = publish(board, "Public board", %{"mode" => "board"})
      {:ok, _} = Boards.unpublish_saved_view(view)

      assert {:error, {:redirect, %{to: "/login"}}} = live(anon, ~p"/p/#{view.public_token}")
    end

    test "a link revoked while it is open sends the reader away", %{board: board, anon: anon} do
      view = publish(board, "Public board", %{"mode" => "board"})
      {:ok, lv, _} = live(anon, ~p"/p/#{view.public_token}")

      {:ok, _} = Boards.unpublish_saved_view(view)

      assert_redirect(lv, "/login")
    end

    test "a deleted view stops working", %{board: board, anon: anon} do
      view = publish(board, "Public board", %{"mode" => "board"})
      {:ok, _} = Boards.delete_saved_view(view)

      assert {:error, {:redirect, %{to: "/login"}}} = live(anon, ~p"/p/#{view.public_token}")
    end

    test "republishing hands out a new link and the old one dies", %{board: board, anon: anon} do
      view = publish(board, "Public board", %{"mode" => "board"})
      {:ok, _} = Boards.unpublish_saved_view(view)
      {:ok, again} = Boards.publish_saved_view(view)

      assert again.public_token != view.public_token
      assert {:error, {:redirect, %{to: "/login"}}} = live(anon, ~p"/p/#{view.public_token}")
      assert {:ok, _, _} = live(anon, ~p"/p/#{again.public_token}")
    end
  end

  describe "staying live" do
    test "a change on the board shows up on the open page", %{
      board: board,
      todo: todo,
      shown: shown,
      anon: anon
    } do
      view = publish(board, "Public board", %{"mode" => "board"})
      {:ok, lv, _} = live(anon, ~p"/p/#{view.public_token}")

      card_fixture(todo, %{"title" => "Fresh card"})
      {:ok, _} = Boards.archive_card(shown)

      html = render(lv)
      assert html =~ "Fresh card"
      refute html =~ "Shown card"
    end

    test "a change to the saved view is picked up too", %{board: board, anon: anon} do
      view = publish(board, "Public board", %{"mode" => "board"})
      {:ok, lv, _} = live(anon, ~p"/p/#{view.public_token}")

      {:ok, _} = Boards.update_saved_view(view, %{"name" => "Renamed view"})

      assert render(lv) =~ "Renamed view"
    end

    test "unrelated messages are ignored", %{board: board, anon: anon} do
      view = publish(board, "Public board", %{"mode" => "board"})
      {:ok, lv, _} = live(anon, ~p"/p/#{view.public_token}")

      send(lv.pid, :something_else)

      assert render(lv) =~ "Shown card"
    end
  end

  describe "the views a share can open in" do
    test "swimlanes, collapsing a row", %{board: board, anon: anon} do
      view = publish(board, "Lanes", %{"mode" => "swimlanes", "rows" => "column"})
      {:ok, lv, html} = live(anon, ~p"/p/#{view.public_token}")

      assert html =~ "Shown card"
      [todo | _] = board.columns
      render_click(lv, "swim_toggle_row", %{"key" => "column:#{todo.id}"})
      assert :sys.get_state(lv.pid).socket.assigns.collapsed |> MapSet.size() == 1
      render_click(lv, "swim_toggle_row", %{"key" => "column:#{todo.id}"})
      assert :sys.get_state(lv.pid).socket.assigns.collapsed |> MapSet.size() == 0
    end

    test "table", %{board: board, anon: anon} do
      view = publish(board, "Tabled", %{"mode" => "table", "fields" => ["title", "due_date"]})
      {:ok, _lv, html} = live(anon, ~p"/p/#{view.public_token}")

      assert html =~ "Shown card"
      refute html =~ "Archived card"
    end

    test "timeline, paged by date from the URL", %{board: board, anon: anon} do
      view = publish(board, "Plan", %{"mode" => "timeline", "unit" => "month"})
      {:ok, lv, html} = live(anon, ~p"/p/#{view.public_token}?date=2030-01-15")

      assert html =~ "Shown card"
      assert has_element?(lv, ~s(a[title="Earlier"]))
      assert has_element?(lv, ~s(a[title="Later"]))

      later = :sys.get_state(lv.pid).socket.assigns.timeline.next
      lv |> element(~s(a[title="Later"])) |> render_click()
      assert_patch(lv, ~p"/p/#{view.public_token}?date=#{later}")
      refute render(lv) =~ "Shown card"

      lv |> element("a", "Today") |> render_click()
      assert_patch(lv, ~p"/p/#{view.public_token}")
    end

    test "calendar, expanding a day", %{board: board, anon: anon} do
      view = publish(board, "Diary", %{"mode" => "calendar", "unit" => "month"})
      {:ok, lv, html} = live(anon, ~p"/p/#{view.public_token}?date=2030-01-15")

      assert html =~ "Shown card"
      assert html =~ "January 2030"

      render_click(lv, "cal_toggle_day", %{"key" => "2030-01-20"})
      assert MapSet.member?(:sys.get_state(lv.pid).socket.assigns.expanded, "2030-01-20")
      render_click(lv, "cal_toggle_day", %{"key" => "2030-01-20"})
      refute MapSet.member?(:sys.get_state(lv.pid).socket.assigns.expanded, "2030-01-20")
    end

    test "outline", %{board: board, anon: anon} do
      view = publish(board, "Tree", %{"mode" => "outline"})
      {:ok, _lv, html} = live(anon, ~p"/p/#{view.public_token}")

      assert html =~ "Shown card"
      refute html =~ "Archived card"
    end

    test "narrative, with a date range the reader can change", %{board: board, anon: anon} do
      view = publish(board, "Story", %{"mode" => "narrative"})
      {:ok, lv, _html} = live(anon, ~p"/p/#{view.public_token}")

      assert has_element?(lv, "form[phx-change=narrative_range]")

      lv
      |> element("form[phx-change=narrative_range]")
      |> render_change(%{"from" => "2030-01-01", "to" => "", "junk" => "x"})

      assert_patch(lv, ~p"/p/#{view.public_token}?from=2030-01-01")
      assert has_element?(lv, ~s(input[name=from][value="2030-01-01"]))
    end

    test "prioritise, which is somebody's own working view, reads as a table", %{
      board: board,
      anon: anon
    } do
      view = publish(board, "Ranked", %{"mode" => "prioritise"})
      {:ok, _lv, html} = live(anon, ~p"/p/#{view.public_token}")

      assert html =~ "Shown card"
      refute html =~ "votes left"
    end
  end
end
