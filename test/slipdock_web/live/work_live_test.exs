defmodule SlipdockWeb.WorkLiveTest do
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures
  alias Slipdock.{Actor, Boards, Repo}

  test "my work lists assigned cards across boards with their paths, grouped by due" do
    user = user_fixture()
    ctx = tree_fixture()
    other = board_fixture(%{"name" => "Other"})
    [col | _] = other.columns
    today = Date.utc_today()

    {:ok, _} =
      Boards.update_card(ctx.e, %{"assignee_id" => user.id, "due_date" => Date.add(today, -3)})

    {:ok, _} = Boards.update_card(ctx.b, %{"assignee_id" => user.id})

    soon =
      card_fixture(col, %{
        "title" => "Soon",
        "assignee_id" => user.id,
        "due_date" => Date.add(today, 2)
      })

    _unassigned = card_fixture(col, %{"title" => "Nobody's"})

    conn = build_conn() |> log_in_user(user)
    {:ok, view, html} = live(conn, ~p"/work")

    assert html =~ "2 open cards assigned to you"
    assert has_element?(view, "#work-overdue #work-card-#{ctx.e.id}")
    assert has_element?(view, "#work-week #work-card-#{soon.id}")
    refute html =~ "Nobody&#39;s"
    # B is completed: hidden until asked for.
    refute has_element?(view, "#work-card-#{ctx.b.id}")
    # The path shows where E sits in its tree.
    assert has_element?(view, "#work-card-#{ctx.e.id} p[title='Root › Epic › C']")

    assert has_element?(
             view,
             "#work-card-#{ctx.e.id} a[href='/boards/#{ctx.subsub.id}/cards/#{ctx.e.id}']"
           )

    view |> element("label input[phx-click=toggle_done]") |> render_click()
    assert has_element?(view, "#work-done #work-card-#{ctx.b.id}")

    view |> element("#work-card-#{soon.id} button[title='Mark complete']") |> render_click()
    assert Boards.get_card!(soon.id).completed
    assert has_element?(view, "#work-done #work-card-#{soon.id}")
  end

  describe "waiting on you (#1118)" do
    setup do
      user = user_fixture()
      asker = user_fixture("asker@example.com")
      board = board_fixture(%{"name" => "Ops"}, owner: asker)
      {:ok, _} = Slipdock.Access.grant(board, user, "write", asker)
      [_backlog, todo | _] = board.columns
      mine = card_fixture(todo, %{"title" => "Mine", "assignee_id" => user.id})
      %{user: user, asker: asker, board: board, todo: todo, mine: mine}
    end

    defp header_count(view) do
      [_, n] = Regex.run(~r/id="waiting-count"[^>]*>\s*(\d+)\s*</, render(view))
      n
    end

    defp ask(ctx, card, attrs \\ %{}) do
      actor = %{Actor.unknown() | kind: "agent", via: "mcp", user_id: ctx.asker.id}

      {:ok, wait} =
        Boards.open_wait(
          card,
          actor,
          Map.merge(%{"needs" => "Which region?", "on_user_id" => ctx.user.id}, attrs)
        )

      wait
    end

    test "opens My work, first, with the count in the header; a choice answers it", ctx do
      card = card_fixture(ctx.todo, %{"title" => "Deploy"})
      wait = ask(ctx, card, %{"choices" => ["eu", "us"]})
      {:ok, _} = Boards.update_card(ctx.mine, %{"due_date" => Date.add(Date.utc_today(), 30)})

      {:ok, view, html} = live(log_in_user(build_conn(), ctx.user), ~p"/work")

      assert has_element?(view, "#work-waiting #waiting-card-#{card.id}", "Deploy")
      assert has_element?(view, "#waiting-card-#{card.id}", "Waiting on you: Which region?")
      assert has_element?(view, "#waiting-card-#{card.id} p[title='Ops']")
      # Before the due-date sections.
      {waiting_at, _} = :binary.match(html, "id=\"work-waiting\"")
      {later_at, _} = :binary.match(html, "id=\"work-later\"")
      assert waiting_at < later_at
      assert header_count(view) == "1"

      view
      |> element("#waiting-card-#{card.id} button[phx-value-choice='2']")
      |> render_click()

      closed = Repo.get!(Slipdock.Boards.Wait, wait.id)
      assert closed.close_reason == "answered"
      assert closed.choice == 2
      assert closed.closed_by_id == ctx.user.id
      refute has_element?(view, "#work-waiting")
      refute has_element?(view, "#waiting-count")
    end

    test "a wait is answered in words too", ctx do
      wait = ask(ctx, ctx.mine)
      {:ok, view, _} = live(log_in_user(build_conn(), ctx.user), ~p"/work")

      view
      |> form("#waiting-answer-#{ctx.mine.id}", wait: %{answer: "eu-west-2"})
      |> render_submit()

      assert Repo.get!(Slipdock.Boards.Wait, wait.id).answer == "eu-west-2"
      refute has_element?(view, "#waiting-card-#{ctx.mine.id}")
      # The card is still assigned; with no due date it is counted, not listed (#2099).
      refute has_element?(view, "#work-card-#{ctx.mine.id}")
      assert has_element?(view, "#work-undated", "1 has no due date and isn't listed.")
    end

    test "a reader who can't change the card can't answer from here", ctx do
      {:ok, _} = Slipdock.Access.grant(ctx.board, ctx.user, "comment", ctx.asker)
      wait = ask(ctx, ctx.mine)
      {:ok, view, _} = live(log_in_user(build_conn(), ctx.user), ~p"/work")

      html =
        render_click(view, "answer_wait", %{
          "card" => to_string(ctx.mine.id),
          "choice" => nil,
          "answer" => "x"
        })

      assert html =~ "read-only access"
      assert is_nil(Repo.get!(Slipdock.Boards.Wait, wait.id).closed_at)
    end

    test "the header count equals the section's length", ctx do
      ask(ctx, ctx.mine)
      other = card_fixture(ctx.todo, %{"title" => "Review me", "assignee_id" => ctx.user.id})
      {:ok, _} = Boards.update_card(other, %{"flags" => ["review"]})

      {:ok, view, _} = live(log_in_user(build_conn(), ctx.user), ~p"/work")

      items = Regex.scan(~r/id="waiting-card-\d+"/, render(view))
      assert length(items) == 2
      assert header_count(view) == "2"
    end

    test "nothing waiting: no section and no number", ctx do
      {:ok, view, _} = live(log_in_user(build_conn(), ctx.user), ~p"/work")
      refute has_element?(view, "#work-waiting")
      refute has_element?(view, "#waiting-count")
      refute has_element?(view, "#waiting-link")
    end

    test "a wait opened in another session shows once the hook's minute is up", ctx do
      {:ok, view, _} = live(log_in_user(build_conn(), ctx.user), ~p"/")
      refute has_element?(view, "#waiting-count")

      ask(ctx, ctx.mine)
      # Not pushed: still nothing until the timer fires.
      refute has_element?(view, "#waiting-count")

      send(view.pid, :refresh_waiting)
      assert header_count(view) == "1"
      assert has_element?(view, "#waiting-link[href='/work']")
    end

    test "every page that renders the layout shows the count", ctx do
      ask(ctx, ctx.mine)
      conn = log_in_user(build_conn(), ctx.user)

      for path <- [
            ~p"/",
            ~p"/work",
            ~p"/favourites",
            ~p"/search",
            ~p"/boards/#{ctx.board.id}",
            ~p"/boards/#{ctx.board.id}/cards/#{ctx.mine.id}"
          ] do
        {:ok, view, _} = live(conn, path)
        assert header_count(view) == "1", "no count on #{path}"
      end
    end
  end

  describe "no due date (#2099)" do
    setup do
      user = user_fixture()
      board = board_fixture(%{"name" => "Plans"}, owner: user)
      [_backlog, todo | _] = board.columns
      %{user: user, todo: todo}
    end

    defp undated(ctx, title, attrs \\ %{}),
      do:
        card_fixture(
          ctx.todo,
          Map.merge(%{"title" => title, "assignee_id" => ctx.user.id}, attrs)
        )

    test "an open card with no due date isn't listed, and the header counts it", ctx do
      dated = undated(ctx, "Dated", %{"due_date" => Date.add(Date.utc_today(), 3)})
      one = undated(ctx, "Someday one")
      two = undated(ctx, "Someday two")

      {:ok, view, html} = live(log_in_user(build_conn(), ctx.user), ~p"/work")

      assert has_element?(view, "#work-week #work-card-#{dated.id}")
      refute has_element?(view, "#work-none")
      refute has_element?(view, "#work-card-#{one.id}")
      refute has_element?(view, "#work-card-#{two.id}")
      refute html =~ "No due date"
      # Counted among the open cards, and said why they aren't below.
      assert html =~ "3 open cards assigned to you"
      assert has_element?(view, "#work-undated", "2 have no due date and aren't listed.")
      refute has_element?(view, "#work-empty")
    end

    test "every card dated: no count line", ctx do
      undated(ctx, "Dated", %{"due_date" => Date.utc_today()})
      {:ok, view, _} = live(log_in_user(build_conn(), ctx.user), ~p"/work")

      refute has_element?(view, "#work-undated")
    end

    test "only undated cards: the empty state doesn't say nothing is assigned", ctx do
      one = undated(ctx, "Someday")
      {:ok, view, html} = live(log_in_user(build_conn(), ctx.user), ~p"/work")

      refute has_element?(view, "#work-card-#{one.id}")
      assert has_element?(view, "#work-undated", "1 has no due date and isn't listed.")
      assert has_element?(view, "#work-empty", "Nothing with a due date")
      refute html =~ "Nothing assigned to you"
    end

    test "nothing assigned at all keeps its own empty state", ctx do
      {:ok, view, _} = live(log_in_user(build_conn(), ctx.user), ~p"/work")

      assert has_element?(view, "#work-empty", "Nothing assigned to you")
      refute has_element?(view, "#work-undated")
    end

    test "a completed undated card still shows under Show completed", ctx do
      done = undated(ctx, "Finished")
      {:ok, _} = Boards.toggle_completed(done)
      open = undated(ctx, "Someday")

      {:ok, view, _} = live(log_in_user(build_conn(), ctx.user), ~p"/work")
      refute has_element?(view, "#work-card-#{done.id}")
      # The completed one isn't counted as hidden: it is under Show completed.
      assert has_element?(view, "#work-undated", "1 has no due date and isn't listed.")

      view |> element("label input[phx-click=toggle_done]") |> render_click()

      assert has_element?(view, "#work-done #work-card-#{done.id}")
      refute has_element?(view, "#work-card-#{open.id}")
      refute has_element?(view, "#work-empty")
    end

    test "the AI chat's source still has every section", ctx do
      one = undated(ctx, "Someday")
      {:ok, view, _} = live(log_in_user(build_conn(), ctx.user), ~p"/work")

      assert [%{key: :none, items: [%{card: %{id: id}}]}] =
               :sys.get_state(view.pid).socket.assigns.sections

      assert id == one.id
    end
  end
end
