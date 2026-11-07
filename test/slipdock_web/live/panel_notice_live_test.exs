defmodule SlipdockWeb.PanelNoticeLiveTest do
  @moduledoc """
  UX-29 (#1973): what an action in the card modal or the page panel says is
  a `<.callout id="panel-notice">` at the top of the panel, never a flash,
  and the next action takes it off again.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Access, Runners}

  setup %{user: user} do
    board = board_fixture(%{"name" => "Panels"}, owner: user)
    column = hd(board.columns)
    card = card_fixture(column, %{"title" => "Fix it"})
    %{board: board, column: column, card: card}
  end

  defp notice(kind), do: "#card-modal #panel-notice[data-callout=#{kind}]"

  defp refute_flash(view) do
    refute has_element?(view, "#flash-error")
    refute has_element?(view, "#flash-info")
  end

  test "an unknown event is said in the panel, not as a toast", ctx do
    {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/cards/#{ctx.card}")
    refute has_element?(view, "#panel-notice")

    view |> with_target("#board-card") |> render_click("no_such_event", %{})

    assert has_element?(view, notice(:error), "That isn't something this page can do.")
    refute_flash(view)
  end

  test "a reader's change is refused in the panel, and the next action clears it", ctx do
    reader = user_fixture("reader@example.com")
    {:ok, _} = Access.grant(ctx.board, reader, "read", ctx.user)

    {:ok, view, _} =
      live(log_in_user(build_conn(), reader), ~p"/boards/#{ctx.board}/cards/#{ctx.card}")

    view |> with_target("#board-card") |> render_click("archive_card", %{})
    assert has_element?(view, notice(:error), "read-only access to this card")
    refute_flash(view)

    # A read event the reader may send runs, and takes the notice away.
    view |> with_target("#board-card") |> render_click("stop_editing_description", %{})
    refute has_element?(view, "#panel-notice")
  end

  test "sharing refused to someone who can't share is said in the panel", ctx do
    commenter = user_fixture("commenter@example.com")
    {:ok, _} = Access.grant(ctx.board, commenter, "read", ctx.user)

    {:ok, view, _} =
      live(log_in_user(build_conn(), commenter), ~p"/boards/#{ctx.board}/cards/#{ctx.card}")

    view |> with_target("#board-card") |> render_click("revoke_grant", %{"id" => "1"})
    assert has_element?(view, notice(:error), "You can't share that.")
    refute_flash(view)
  end

  test "a job's cancel says what happened in the panel", ctx do
    {:ok, runner, _} = Runners.create_runner(ctx.board, %{"name" => "laptop", "pool" => "dev"})
    {:ok, queued} = Runners.queue(ctx.card, %{pool: "dev", kind: "claude", prompt: "go"})
    {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/cards/#{ctx.card}")

    view |> element("#card-job-#{queued.id} button", "Cancel") |> render_click()
    assert has_element?(view, notice(:info), "Job ##{queued.id} cancelled.")
    refute_flash(view)

    {:ok, running} = Runners.queue(ctx.card, %{pool: "dev", kind: "claude", prompt: "go"})
    Runners.claim(runner)
    render(view)
    assert has_element?(view, "#card-job-#{running.id}", "laptop")

    view |> element("#card-job-#{running.id} button", "Cancel") |> render_click()
    assert has_element?(view, notice(:info), "Asked the runner to stop job ##{running.id}.")
  end

  test "a card's notice doesn't follow the reader to another card", ctx do
    other = card_fixture(ctx.column, %{"title" => "Another"})
    {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/cards/#{ctx.card}")

    view |> with_target("#board-card") |> render_click("no_such_event", %{})
    assert has_element?(view, "#panel-notice")

    render_patch(view, ~p"/boards/#{ctx.board}/cards/#{other}")
    assert has_element?(view, "#card-modal", "Another")
    refute has_element?(view, "#panel-notice")
  end

  test "Duplicate's notice is shown on the copy it opens", ctx do
    {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/cards/#{ctx.card}")
    view |> element("#duplicate-card") |> render_click()

    assert has_element?(view, notice(:info), "Duplicated as #")
    refute_flash(view)
  end

  test "the page panel says a refusal at its top too (shared item events)", ctx do
    page = page_fixture(ctx.board, %{"title" => "Placed"}, user: ctx.user)
    {:ok, _} = Slipdock.Wiki.place(page, ctx.column)
    {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}?#{[page: page.id]}")
    refute has_element?(view, "#page-panel #panel-notice")

    view |> with_target("#board-page") |> render_click("add_status_update", %{"health" => ""})
    assert has_element?(view, "#page-panel #panel-notice[data-callout=error]", "Pick a health")
    refute_flash(view)

    view |> with_target("#board-page") |> render_click("no_such_event", %{})

    assert has_element?(
             view,
             "#page-panel #panel-notice",
             "That isn't something this page can do."
           )
  end
end
