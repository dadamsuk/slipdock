defmodule SlipdockWeb.WorkDismissLiveTest do
  @moduledoc """
  Waiting on you, trimmed in the web (#2069): the × on a row dismisses it,
  the counts line says what is hidden, the dismissed items and muted boards
  open with Undo and Unmute, and a board's menu mutes its tree with a strip
  on the board saying so, for me alone.
  """
  use SlipdockWeb.ConnCase, async: true

  import Ecto.Query
  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Boards, Repo, Runners, Work}
  alias Slipdock.Runners.Job

  setup do
    owner = user_fixture("owner@example.com")
    dana = user_fixture("dana@example.com")
    board = board_fixture(%{"name" => "Ops"}, owner: owner)
    [_backlog, todo | _] = board.columns
    {:ok, _} = Slipdock.Access.grant(board, dana, "write", owner)
    %{owner: owner, dana: dana, board: board, todo: todo}
  end

  defp failed_job(card) do
    {:ok, job} = Runners.queue(card, %{pool: "dev", kind: "claude", prompt: "go"})
    from(j in Job, where: j.id == ^job.id) |> Repo.update_all(set: [status: "failed"])
    Repo.get!(Job, job.id)
  end

  test "the × dismisses for me; Undo brings it back; the counts say so", ctx do
    card = card_fixture(ctx.todo, %{"title" => "Flaky", "assignee_ids" => [ctx.dana.id]})
    agent = %{Slipdock.Actor.unknown() | kind: "agent", via: "mcp", user_id: ctx.dana.id}
    {:ok, _} = Boards.Waits.open_wait(card, agent, %{"needs" => "Region?"})
    other = card_fixture(ctx.todo, %{"title" => "Other"})
    failed_job(other)

    {:ok, view, _} = live(log_in_user(build_conn(), ctx.owner), ~p"/work")
    assert has_element?(view, "#waiting-card-#{other.id}")
    refute has_element?(view, "#work-waiting-hidden")

    view |> element("#dismiss-waiting-#{other.id}") |> render_click()

    refute has_element?(view, "#waiting-card-#{other.id}")
    assert view |> element("#work-waiting-hidden") |> render() =~ "1 waiting · 1 dismissed"
    assert Work.dismissed(ctx.owner) |> Enum.map(& &1.card.id) == [other.id]

    # The dismissed list, with Undo.
    refute has_element?(view, "#work-dismissed")
    view |> element("#work-waiting-hidden-toggle") |> render_click()

    assert has_element?(
             view,
             "#dismissed-card-#{other.id}",
             "Job ##{hd(Repo.all(Job)).id} failed"
           )

    view |> element("#dismissed-card-#{other.id} button", "Undo") |> render_click()
    assert has_element?(view, "#waiting-card-#{other.id}")
    refute has_element?(view, "#work-waiting-hidden")

    # Dana's list was never touched: dismiss the shared card, she still has it.
    view |> element("#dismiss-waiting-#{card.id}") |> render_click()
    {:ok, hers, _} = live(log_in_user(build_conn(), ctx.dana), ~p"/work")
    assert has_element?(hers, "#waiting-card-#{card.id}")
  end

  test "a dismissed card with a new cause shows again", ctx do
    card = card_fixture(ctx.todo, %{"title" => "Flaky"})
    failed_job(card)
    {:ok, view, _} = live(log_in_user(build_conn(), ctx.owner), ~p"/work")
    view |> element("#dismiss-waiting-#{card.id}") |> render_click()
    refute has_element?(view, "#waiting-card-#{card.id}")

    failed_job(card)
    {:ok, view, _} = live(log_in_user(build_conn(), ctx.owner), ~p"/work")
    assert has_element?(view, "#waiting-card-#{card.id}")
  end

  test "a board's menu mutes its tree for me, the board says so, and Unmute lifts it", ctx do
    card = card_fixture(ctx.todo, %{"title" => "Flaky"})
    failed_job(card)
    {:ok, t} = Boards.Templates.find_template(nil, "Simple")
    {:ok, sub} = sub_board(card_fixture(ctx.todo, %{"title" => "Epic"}), t)

    {:ok, board_view, _} = live(log_in_user(build_conn(), ctx.owner), ~p"/boards/#{ctx.board.id}")
    refute has_element?(board_view, "#waiting-muted-banner")
    board_view |> element("#board-share-mute-waiting") |> render_click()

    assert has_element?(board_view, "#waiting-muted-banner", "Muted on your Waiting on you")
    assert has_element?(board_view, "#board-share-unmute-waiting")
    assert Work.waiting_on_me(ctx.owner) == []

    # The sub-board shows it too, naming the board above that muted it.
    {:ok, sub_view, _} = live(log_in_user(build_conn(), ctx.owner), ~p"/boards/#{sub.id}")
    assert has_element?(sub_view, "#waiting-muted-banner", "by Ops")

    # Dana sees no strip: the mute is mine.
    {:ok, hers, _} = live(log_in_user(build_conn(), ctx.dana), ~p"/boards/#{ctx.board.id}")
    refute has_element?(hers, "#waiting-muted-banner")
    assert has_element?(hers, "#board-share-mute-waiting")

    # My work lists the muted board, with Unmute.
    {:ok, work, _} = live(log_in_user(build_conn(), ctx.owner), ~p"/work")
    assert work |> element("#work-waiting-hidden") |> render() =~ "0 waiting · 1 board muted"
    work |> element("#work-waiting-hidden-toggle") |> render_click()
    work |> element("#muted-board-#{ctx.board.id} button", "Unmute") |> render_click()
    assert has_element?(work, "#waiting-card-#{card.id}")

    # Muted again from the board, the strip's own Unmute lifts it too.
    board_view |> element("#board-share-unmute-waiting") |> render_click()
    board_view |> element("#board-share-mute-waiting") |> render_click()
    board_view |> element("#waiting-muted-unmute") |> render_click()
    refute has_element?(board_view, "#waiting-muted-banner")
    assert [_] = Work.waiting_on_me(ctx.owner)
  end
end
