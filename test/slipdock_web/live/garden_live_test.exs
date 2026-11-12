defmodule SlipdockWeb.GardenLiveTest do
  @moduledoc """
  The Tidy-up page and the Gardening settings (W-1807): suggestions grouped
  with their evidence, apply, dismiss, alternatives, apply all, duplicates
  side by side, undo, read-only access, and per-check settings.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures
  import Ecto.Query

  alias Slipdock.{Access, Boards, Gardener, Repo}
  alias Slipdock.Gardener.Settings
  alias Slipdock.Search.{Embedding, Vector}

  setup %{user: owner} do
    board = board_fixture(%{}, owner: owner)
    [_backlog, todo, doing, done] = board.columns
    %{owner: owner, board: board, todo: todo, doing: doing, done: done}
  end

  defp stray(ctx, title), do: card_fixture(ctx.doing, %{"title" => title, "completed" => true})

  defp tidy(conn, ctx), do: live(conn, ~p"/boards/#{ctx.board}/tidy")

  test "empty until looked over; Look the board over finds things", ctx do
    stray(ctx, "Finished thing")
    {:ok, view, _html} = tidy(ctx.conn, ctx)

    assert has_element?(view, "#garden-empty", "Look the board over for finished epics")
    view |> element("#garden-run") |> render_click()

    assert has_element?(view, "#garden-completed_not_done", "Complete but not in Done")
    assert render(view) =~ "“Finished thing” is complete but still in “In Progress”, not “Done”"
    assert render(view) =~ "Move “Finished thing” to “Done”"
    assert render(view) =~ "1 suggestion(s), 1 new"
  end

  test "Apply moves the card; Recently applied can undo it", ctx do
    card = stray(ctx, "Finished")
    {:ok, _} = Gardener.run(ctx.board)
    [s] = Gardener.list_open(ctx.board)
    {:ok, view, _} = tidy(ctx.conn, ctx)

    view |> element("#suggestion-#{s.id} button", "Apply") |> render_click()
    assert Boards.Cards.get_card!(card.id).column_id == ctx.done.id
    refute has_element?(view, "#suggestion-#{s.id}")
    assert has_element?(view, "#applied-#{s.id}")

    view |> element("#applied-#{s.id} button", "Undo") |> render_click()
    assert Boards.Cards.get_card!(card.id).column_id == ctx.doing.id
    assert has_element?(view, "#suggestion-#{s.id}")
  end

  describe "a proposed handbook edit (#1788)" do
    setup ctx do
      body =
        "# UX & UI\n\n## Patterns\n\nLists stream.\n\n## Rules\n\n" <>
          "- **UX-1** must · judgement · Tokens only.\n"

      {:ok, page} = Slipdock.Wiki.create_page(ctx.board, %{"title" => "UX & UI", "body" => body})

      {:ok, s, :new} =
        Gardener.propose(ctx.board, ctx.owner, %{
          "explanation" => "UX-1 keeps breaking: say which tokens",
          "steps" => [
            %{
              "op" => "edit_section",
              "page" => page.code,
              "section" => "UX & UI/Rules",
              "body" => "- **UX-1** must · judgement · Design tokens only."
            }
          ]
        })

      Map.merge(ctx, %{page: page, proposal: s})
    end

    test "shows the section's diff, and Apply then Undo edit the page", ctx do
      s = ctx.proposal
      {:ok, view, _} = tidy(ctx.conn, ctx)

      assert has_element?(view, "#garden-proposal", "Proposed edits")
      assert has_element?(view, "#suggestion-#{s.id}", "Edit §UX & UI/Rules of “UX & UI”")
      diff = "#suggestion-#{s.id}-diff-0"
      assert has_element?(view, diff, "“UX & UI” §UX & UI/Rules")

      assert has_element?(
               view,
               "#{diff} [data-op=del]",
               "- - **UX-1** must · judgement · Tokens only."
             )

      assert has_element?(
               view,
               "#{diff} [data-op=ins]",
               "+ - **UX-1** must · judgement · Design tokens only."
             )

      # Unchanged lines far from the change are left out.
      refute has_element?(view, diff, "Lists stream.")

      view |> element("#suggestion-#{s.id} button", "Apply") |> render_click()
      assert Repo.get!(Slipdock.Wiki.Page, ctx.page.id).body =~ "Design tokens only."
      assert has_element?(view, "#applied-#{s.id}")

      view |> element("#applied-#{s.id} button", "Undo") |> render_click()
      assert Repo.get!(Slipdock.Wiki.Page, ctx.page.id).body == ctx.page.body
      assert has_element?(view, "#suggestion-#{s.id}")
    end

    # #2668: the page is where a person-only suggestion is decided.
    test "Dismiss on the page dismisses it", ctx do
      s = ctx.proposal
      {:ok, view, _} = tidy(ctx.conn, ctx)

      view |> element("#suggestion-#{s.id} button", "Dismiss") |> render_click()
      assert Gardener.get_suggestion(s.id).state == "dismissed"
      assert Gardener.get_suggestion(s.id).decided_by_id == ctx.owner.id
      assert Repo.get!(Slipdock.Wiki.Page, ctx.page.id).body == ctx.page.body
    end

    test "a section edited since says so, and Apply is refused with the reason", ctx do
      s = ctx.proposal

      {:ok, _} =
        Slipdock.Wiki.replace_section(
          ctx.page,
          "UX & UI/Rules",
          "- **UX-1** must · judgement · Changed."
        )

      {:ok, view, _} = tidy(ctx.conn, ctx)

      assert has_element?(
               view,
               "#suggestion-#{s.id}-diff-0",
               "The section has changed since this was proposed."
             )

      html = view |> element("#suggestion-#{s.id} button", "Apply") |> render_click()
      assert html =~ "has changed since this was proposed"
      assert Gardener.get_suggestion(s.id).state == "open"
    end

    test "proposals have no Apply all", ctx do
      {:ok, _, :new} =
        Gardener.propose(ctx.board, ctx.owner, %{
          "explanation" => "Another",
          "steps" => [
            %{
              "op" => "edit_section",
              "page" => ctx.page.id,
              "section" => "UX & UI/Patterns",
              "body" => "Lists stream, always."
            }
          ]
        })

      {:ok, view, _} = tidy(ctx.conn, ctx)
      refute has_element?(view, "#garden-apply-all-proposal")
    end
  end

  test "Dismiss takes it away for good", ctx do
    stray(ctx, "Finished")
    {:ok, _} = Gardener.run(ctx.board)
    [s] = Gardener.list_open(ctx.board)
    {:ok, view, _} = tidy(ctx.conn, ctx)

    view |> element("#suggestion-#{s.id} button", "Dismiss") |> render_click()
    refute has_element?(view, "#suggestion-#{s.id}")
    assert Gardener.get_suggestion(s.id).state == "dismissed"
  end

  test "an alternative is a button of its own", ctx do
    card = card_fixture(ctx.doing, %{"title" => "Stuck"})
    old = DateTime.add(DateTime.utc_now(:second), -20 * 86_400)
    Repo.update_all(from(c in Boards.Card, where: c.id == ^card.id), set: [updated_at: old])

    Repo.update_all(from(a in Boards.Activity, where: a.card_id == ^card.id),
      set: [inserted_at: old]
    )

    {:ok, _} = Gardener.run(ctx.board, only: ["stale_in_progress"])
    [s] = Gardener.list_open(ctx.board)
    {:ok, view, _} = tidy(ctx.conn, ctx)

    view |> element("#suggestion-#{s.id} button", "Snooze") |> render_click()
    assert Repo.reload!(card).snoozed_until
  end

  test "Apply all in this group applies each", ctx do
    a = stray(ctx, "One")
    b = stray(ctx, "Two")
    {:ok, _} = Gardener.run(ctx.board)
    {:ok, view, _} = tidy(ctx.conn, ctx)

    view |> element("#garden-apply-all-completed_not_done") |> render_click()
    assert Boards.Cards.get_card!(a.id).column_id == ctx.done.id
    assert Boards.Cards.get_card!(b.id).column_id == ctx.done.id
    assert render(view) =~ "Applied 2."
  end

  test "a duplicate is shown side by side; Keep this one archives the other", ctx do
    a = card_fixture(ctx.todo, %{"title" => "Fix login", "description" => "It breaks"})
    b = card_fixture(ctx.todo, %{"title" => "Login broken"})

    for {card, x} <- [{a, 1.0}, {b, 0.999}] do
      Repo.delete_all(from(e in Embedding, where: e.card_id == ^card.id))

      Repo.insert!(%Embedding{
        kind: "card",
        source_id: card.id,
        section: "",
        body: card.title,
        content_hash: "stub",
        model: Slipdock.AI.Embeddings.model(),
        dimensions: 2,
        vector: Vector.pack([x, :math.sqrt(1 - x * x)]),
        card_id: card.id,
        board_id: card.board_id
      })
    end

    {:ok, _} = Gardener.run(ctx.board, only: ["duplicate_cards"])
    [s] = Gardener.list_open(ctx.board)
    {:ok, view, _} = tidy(ctx.conn, ctx)

    assert has_element?(view, "#suggestion-#{s.id}-card-#{a.id}", "It breaks")
    assert has_element?(view, "#suggestion-#{s.id}-card-#{b.id}", "Login broken")
    refute has_element?(view, "#suggestion-#{s.id} button", "Apply")

    view |> element("#suggestion-#{s.id}-card-#{a.id} button", "Keep this one") |> render_click()
    assert Repo.reload!(b).archived_at
    refute Repo.reload!(a).archived_at
  end

  test "somebody who can only read sees the suggestions but no buttons", ctx do
    stray(ctx, "Finished")
    {:ok, _} = Gardener.run(ctx.board)
    [s] = Gardener.list_open(ctx.board)
    reader = user_fixture("tidy-reader@example.com")
    {:ok, _} = Access.grant(ctx.board, reader, "read", ctx.owner)

    {:ok, view, _} = tidy(conn_as(reader), ctx)
    assert has_element?(view, "#suggestion-#{s.id}")
    refute has_element?(view, "#garden-run")
    refute has_element?(view, "#suggestion-#{s.id} button")

    render_hook(view, "apply", %{"id" => "#{s.id}"})
    assert render(view) =~ "read-only access"
    assert Gardener.get_suggestion(s.id).state == "open"
  end

  test "a board somebody can't read sends them home", ctx do
    stranger = user_fixture("tidy-stranger@example.com")
    assert {:error, {:live_redirect, %{to: "/"}}} = tidy(conn_as(stranger), ctx)
  end

  test "the board menu has Tidy up…", ctx do
    {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}")
    assert has_element?(view, ~s(a[href="/boards/#{ctx.board.id}/tidy"]), "Tidy up…")
  end

  describe "Gardening in board settings" do
    test "lists every check; switching one off and a threshold save as made", ctx do
      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/settings")
      assert has_element?(view, "#gardening-epic_done", "Epics whose work is all done")

      assert has_element?(
               view,
               "#gardening-abandoned_backlog input[type=checkbox]:not([checked])"
             )

      view
      |> form("#gardening-form", %{
        "gardening" => %{
          "epic_done" => %{"enabled" => "false"},
          "stale_in_progress" => %{"days" => "21"}
        }
      })
      |> render_change()

      board = Repo.reload!(ctx.board)
      refute Settings.enabled?(board, Slipdock.Gardener.Checks.EpicDone)
      assert Settings.for(board, Slipdock.Gardener.Checks.StaleInProgress)["days"] == 21
    end

    test "a bad threshold is refused with the reason", ctx do
      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/settings")

      view
      |> form("#gardening-form", %{"gardening" => %{"long_overdue" => %{"days" => "0"}}})
      |> render_change()

      # The panel's flash reaches the page on the next render.
      assert render(view) =~ "Long overdue: days must be a whole number above 0"
      assert Repo.reload!(ctx.board).gardening == %{}
    end
  end
end
