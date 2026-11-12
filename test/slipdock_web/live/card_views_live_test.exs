defmodule SlipdockWeb.CardViewsLiveTest do
  @moduledoc """
  Card views in the web app (#2031): the editor at /card-views, the Display
  menu's Show all and the list menu's link, and what the board and the opened
  card draw from them.
  """
  use SlipdockWeb.ConnCase, async: true

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Boards, CardViews, Runners}

  setup %{user: user} do
    board = board_fixture(%{"name" => "Plan", "code" => unique_code()}, owner: user)
    [todo, doing | _] = board.columns
    tag = tag_fixture(board, "ux")

    card =
      card_fixture(todo, %{"title" => "Tagged", "due_date" => "2030-01-20", "priority" => "high"})

    {:ok, card} = Boards.Cards.set_card_tags(card, [tag])
    other = card_fixture(doing, %{"title" => "Elsewhere", "priority" => "high"})
    %{board: board, todo: todo, doing: doing, card: card, other: other}
  end

  defp priority(card), do: "#card-#{card.id} [title^='Priority']"

  describe "the editor" do
    test "sets an element at the global level, and the preview follows", %{conn: conn, user: user} do
      {:ok, view, _} = live(conn, ~p"/card-views")
      assert has_element?(view, "#card-view-title", "Global")
      assert has_element?(view, "#sample-card [title^='Priority']")
      # The choice travels as `to`: a clicked button would send its own empty
      # `value` over `phx-value-value` in a browser (#553, tools/e2e/card-views.sh).
      assert has_element?(view, "#element-priority button[phx-value-to=hide]")
      refute has_element?(view, "#card-view-editor button[phx-value-value]")

      view
      |> element("#element-priority button[data-value=hide]")
      |> render_click()

      assert CardViews.level(user, :global).elements == %{"priority" => false}
      refute has_element?(view, "#sample-card [title^='Priority']")
      assert has_element?(view, "#element-priority button[data-value=hide][aria-pressed=true]")

      view |> element("#element-priority button[data-value=inherit]") |> render_click()
      assert CardViews.level(user, :global).elements == %{}
      assert has_element?(view, "#sample-card [title^='Priority']")
    end

    test "a board's level says where each value comes from, and has Show all", ctx do
      {:ok, _} = CardViews.update_level(ctx.user, :global, %{"hide" => "tags"})
      {:ok, view, _} = live(ctx.conn, ~p"/card-views?board=#{ctx.board.id}")

      assert has_element?(view, "#level-board.btn-primary")
      assert has_element?(view, "#element-tags [data-role=source]", "hidden · global")
      assert has_element?(view, "#element-priority [data-role=source]", "shown · default")

      view |> element("#card-view-show-all") |> render_click()
      assert CardViews.level(ctx.user, {:board, ctx.board}).show_all
      assert has_element?(view, "#element-tags [data-role=source]", "shown · show all")
    end

    test "a list's level, an opened card's section, and Inherit all", ctx do
      {:ok, view, _} = live(ctx.conn, ~p"/card-views?board=#{ctx.board.id}&list=#{ctx.todo.id}")
      assert has_element?(view, "#card-view-title", "Plan › #{ctx.todo.name}")
      refute has_element?(view, "#card-view-show-all")

      # The card front's tab first; the opened card's elements are the other tab's.
      assert has_element?(view, "#element-tags")
      refute has_element?(view, "#element-open-comments")
      view |> element("#card-view-tab-card") |> render_click()
      refute has_element?(view, "#element-tags")
      assert has_element?(view, "#element-side-votes")

      view |> element("#element-open-comments button[data-value=hide]") |> render_click()
      assert has_element?(view, "#sample-panel li[data-key='open.comments'][data-shown=false]")

      assert CardViews.level(ctx.user, {:list, ctx.board, ctx.todo}).elements ==
               %{"open.comments" => false}

      view |> element("#reset-card-view") |> render_click()
      assert CardViews.level(ctx.user, {:list, ctx.board, ctx.todo}).elements == %{}
    end

    test "saves a named view from a level, edits, renames, applies and deletes it", ctx do
      {:ok, _} = CardViews.update_level(ctx.user, :global, %{"hide" => "tags"})
      {:ok, view, _} = live(ctx.conn, ~p"/card-views?board=#{ctx.board.id}")

      view |> form("#new-card-view", %{"card_view" => %{"name" => "Lean"}}) |> render_submit()
      {:ok, lean} = CardViews.get(ctx.user, "Lean")
      # It starts as what the level shows, stated in full.
      assert lean.elements["tags"] == false and lean.elements["priority"] == true
      assert_patch(view, ~p"/card-views?board=#{ctx.board.id}&view=#{lean.id}")
      assert has_element?(view, "#card-view-title", "Card view “Lean”")

      view |> element("#element-due_date button[data-value=hide]") |> render_click()
      assert {:ok, %{elements: %{"due_date" => false}}} = CardViews.get(ctx.user, lean.id)

      view |> element("button", "Rename") |> render_click()
      view |> form("#rename-card-view", %{"rename" => %{"name" => "Leaner"}}) |> render_submit()
      assert has_element?(view, "#card-view-title", "Card view “Leaner”")

      # Applied at the board's level.
      {:ok, view, _} = live(ctx.conn, ~p"/card-views?board=#{ctx.board.id}")
      view |> form("#apply-card-view", %{"apply" => %{"card_view" => lean.id}}) |> render_change()
      assert CardViews.level(ctx.user, {:board, ctx.board}).card_view_id == lean.id
      assert has_element?(view, "#element-due_date [data-role=source]", "hidden · board")

      {:ok, view, _} = live(ctx.conn, ~p"/card-views?view=#{lean.id}")
      view |> element("#delete-card-view") |> render_click()
      assert_patch(view, ~p"/card-views")
      assert CardViews.list(ctx.user) == []
      # The board's level applied it: it inherits now, and the page says so.
      assert render(view) =~ "The one level that applied it inherits instead."
      assert is_nil(CardViews.level(ctx.user, {:board, ctx.board}).card_view_id)
    end

    test "a duplicate or blank name is said, not saved", ctx do
      {:ok, _} = CardViews.create(ctx.user, %{"name" => "Lean"})
      {:ok, view, _} = live(ctx.conn, ~p"/card-views")
      view |> form("#new-card-view", %{"card_view" => %{"name" => "Lean"}}) |> render_submit()
      assert has_element?(view, "#card-view-error", "already have a card view of that name")
      assert length(CardViews.list(ctx.user)) == 1
    end

    test "a board, list or view that isn't the reader's goes back to the global level", ctx do
      stranger = user_fixture("stranger-#{System.unique_integer([:positive])}@example.com")
      {:ok, theirs} = CardViews.create(stranger, %{"name" => "Theirs"})
      theirs_board = board_fixture(%{"name" => "Theirs"}, owner: stranger)

      for path <- [
            ~p"/card-views?board=#{theirs_board.id}",
            ~p"/card-views?board=#{ctx.board.id}&list=#{hd(theirs_board.columns).id}",
            ~p"/card-views?list=#{ctx.todo.id}",
            ~p"/card-views?view=#{theirs.id}",
            ~p"/card-views?board=nope"
          ] do
        assert {:error, {:live_redirect, %{to: "/card-views", flash: flash}}} =
                 live(ctx.conn, path)

        assert flash["error"] =~ "isn't one of yours"
      end
    end
  end

  describe "the board" do
    test "the Display menu's Show all shows every front element, and is kept per board", ctx do
      CardViews.update_level(ctx.user, :global, %{"hide" => "priority,tags"})
      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}")
      refute has_element?(view, priority(ctx.card))

      view |> element("#toggle-show-all") |> render_click()
      assert has_element?(view, priority(ctx.card))
      assert has_element?(view, "#toggle-show-all[aria-pressed=true]")
      assert CardViews.level(ctx.user, {:board, ctx.board}).show_all

      # Remembered for the board, on the server: a fresh visit has it on.
      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}")
      assert has_element?(view, priority(ctx.card))

      # Another board of theirs keeps its own.
      elsewhere = board_fixture(%{"name" => "Elsewhere"}, owner: ctx.user)
      card = card_fixture(hd(elsewhere.columns), %{"title" => "Plain", "priority" => "high"})
      {:ok, view2, _} = live(ctx.conn, ~p"/boards/#{elsewhere}")
      refute has_element?(view2, priority(card))

      view |> element("#toggle-show-all") |> render_click()
      refute has_element?(view, priority(ctx.card))
    end

    test "Show all never brings back what a simple board hides", ctx do
      {:ok, board} = Boards.update_board(ctx.board, %{"simple" => true})
      {:ok, _} = Boards.Cards.update_card(ctx.card, %{"percent_complete" => 40})
      {:ok, _} = CardViews.put_show_all(ctx.user, board, true)
      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{board}")
      assert has_element?(view, priority(ctx.card))
      refute has_element?(view, "#card-#{ctx.card.id} [title='40% complete']")
    end

    test "a list's level decides for that list's cards only", ctx do
      {:ok, _} =
        CardViews.update_level(ctx.user, {:list, ctx.board, ctx.todo}, %{"hide" => "priority"})

      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}")
      refute has_element?(view, priority(ctx.card))
      assert has_element?(view, priority(ctx.other))

      # Swimlanes take each card's list too.
      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/swimlanes")
      refute has_element?(view, "[id$='-card-#{ctx.card.id}'] [title^='Priority']")
      assert has_element?(view, "[id$='-card-#{ctx.other.id}'] [title^='Priority']")
    end

    test "each list's menu links to its level, and the Display menu to the board's", ctx do
      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}")

      assert has_element?(
               view,
               ~s(#card-view-list-#{ctx.todo.id}[href="/card-views?board=#{ctx.board.id}&list=#{ctx.todo.id}"])
             )

      assert has_element?(view, ~s(#edit-card-views[href="/card-views?board=#{ctx.board.id}"]))
    end

    test "the marks the tile always drew can be hidden now", ctx do
      {:ok, _} =
        Boards.Handoffs.leave_handoff(ctx.card, ctx.user, %{next_step: "Go on", via: "ui"})

      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}")
      assert has_element?(view, "#card-#{ctx.card.id} [data-role=handoff-mark]")

      {:ok, _} = CardViews.update_level(ctx.user, :global, %{"hide" => "handoff"})
      refute has_element?(view, "#card-#{ctx.card.id} [data-role=handoff-mark]")
    end
  end

  describe "the opened card" do
    test "hides the sections and sidebar groups the card view hides", ctx do
      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/cards/#{ctx.card.id}")
      assert has_element?(view, "#card-modal [data-section-key=d]")
      assert has_element?(view, "#card-modal [data-section-key=c]")

      assert has_element?(
               view,
               "#card-modal [data-role=card-borders-form], #card-modal aside",
               "Cover"
             )

      {:ok, _} =
        CardViews.update_level(ctx.user, {:list, ctx.board, ctx.todo}, %{
          "hide" => "open.description,open.comments,side.cover"
        })

      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/cards/#{ctx.card.id}")
      refute has_element?(view, "#card-modal [data-section-key=d]")
      refute has_element?(view, "#card-modal [data-section-key=c]")
      refute has_element?(view, "#card-modal aside", "Cover")
      # Properties not hidden stay: the title and the sidebar itself remain.
      assert has_element?(view, "#card-modal aside")
      assert has_element?(view, "#card-modal [data-prop=priority]")

      # Another list's card keeps them.
      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/cards/#{ctx.other.id}")
      assert has_element?(view, "#card-modal [data-section-key=d]")
    end
  end

  describe "the opened card's properties (#2070)" do
    @props ~w(assignees priority percent start due health)

    test "each is shown by default, and the card view can hide every one", ctx do
      past = Date.add(Date.utc_today(), -3)

      {:ok, card} =
        Boards.Cards.update_card(ctx.card, %{
          "start_date" => Date.add(past, -2),
          "due_date" => past
        })

      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/cards/#{card.id}")
      for p <- @props, do: assert(has_element?(view, "#card-modal [data-prop=#{p}]"), p)
      assert has_element?(view, "#card-props-more-toggle")
      assert has_element?(view, "#card-authors")
      assert has_element?(view, "#card-past-due")
      assert has_element?(view, "#card-modal [data-role=start-words]")

      hide = Enum.map_join(Slipdock.CardViews.Elements.side(), ",", &elem(&1, 0))
      {:ok, _} = CardViews.update_level(ctx.user, {:board, ctx.board}, %{"hide" => hide})

      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/cards/#{card.id}")

      for p <- @props ++ ["precision"],
          do: refute(has_element?(view, "#card-modal [data-prop=#{p}]"), p)

      refute has_element?(view, "#card-props-more-toggle")
      refute has_element?(view, "#card-authors")
      refute has_element?(view, "#card-past-due")
      refute has_element?(view, "#card-modal [data-role=start-words]")
    end

    test "the runner chip shows by default and goes with Assignees", ctx do
      # A running job draws the chip (the card's screenshot: "BigWhite · build").
      {:ok, runner, _} =
        Runners.create_runner(ctx.board, %{"name" => "Mac Studio", "pool" => "dev"})

      {:ok, _} = Runners.queue(ctx.card, %{pool: "dev", kind: "claude", prompt: "go"})
      %Runners.Job{} = job = Runners.claim(runner)
      {:ok, :ok} = Runners.heartbeat(runner, job.id)

      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/cards/#{ctx.card.id}")
      assert has_element?(view, "#card-assignee-loop", "Mac Studio · build")

      {:ok, _} =
        CardViews.update_level(ctx.user, {:board, ctx.board}, %{"hide" => "side.assignees"})

      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/cards/#{ctx.card.id}")
      refute has_element?(view, "#card-assignee-loop")
      refute has_element?(view, "#card-modal [data-prop=assignees]")
      # The job itself is still there: only the sidebar row went.
      assert has_element?(view, "#card-job-#{job.id}")
    end

    test "dates from subcards show by default and go with side.rollup", ctx do
      {:ok, t} = Boards.Templates.find_template(nil, "Simple")
      {:ok, sub} = sub_board(ctx.card, t)
      sub = Boards.get_board!(sub.id)

      card_fixture(hd(sub.columns), %{
        "title" => "Dated",
        "start_date" => "2030-01-05",
        "due_date" => "2030-01-25"
      })

      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/cards/#{ctx.card.id}")
      assert has_element?(view, "#card-rollup-dates")

      {:ok, _} = CardViews.update_level(ctx.user, {:board, ctx.board}, %{"hide" => "side.rollup"})

      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/cards/#{ctx.card.id}")
      refute has_element?(view, "#card-rollup-dates")
      # Only what was hidden goes.
      assert has_element?(view, "#card-modal [data-prop=due]")
    end

    test "a precision other than day is hidden with the rest, one property at a time", ctx do
      {:ok, card} = Boards.Cards.update_card(ctx.card, %{"date_precision" => "month"})
      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/cards/#{card.id}")
      assert has_element?(view, "#card-modal [data-prop=precision]")

      {:ok, _} =
        CardViews.update_level(ctx.user, {:board, ctx.board}, %{
          "hide" => "side.precision,side.priority"
        })

      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/cards/#{card.id}")
      refute has_element?(view, "#card-modal [data-prop=precision]")
      refute has_element?(view, "#card-modal [data-prop=priority]")
      # Only what was hidden goes.
      assert has_element?(view, "#card-modal [data-prop=due]")
      assert has_element?(view, "#card-modal [data-prop=assignees]")
    end
  end

  describe "reaching it" do
    test "account settings link to the editor", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/account/settings")
      assert has_element?(view, ~s(#card-views-settings-link[href="/card-views"]))
    end
  end

  describe "a hidden section that needs attention" do
    test "is named in a callout, and Show them brings the hidden sections back on this card",
         ctx do
      {1, _} =
        Slipdock.Repo.update_all(
          from(c in Slipdock.Boards.Card, where: c.id == ^ctx.card.id),
          set: [verify_state: "rejected", verify_note: "bar 1: not met"]
        )

      {:ok, _} =
        CardViews.update_level(ctx.user, {:board, ctx.board}, %{
          "hide" => "open.verification,open.description"
        })

      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/cards/#{ctx.card.id}")
      assert has_element?(view, "#card-view-hidden-attention", "a rejected verification")
      refute has_element?(view, "#card-modal [data-section-key=d]")

      view |> element("#reveal-hidden-sections") |> render_click()
      refute has_element?(view, "#card-view-hidden-attention")
      assert has_element?(view, "#card-modal [data-section-key=d]")

      # Another card with nothing waiting gets no callout for what is hidden.
      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/cards/#{ctx.other.id}")
      refute has_element?(view, "#card-view-hidden-attention")
      refute has_element?(view, "#card-modal [data-section-key=d]")
    end
  end
end
