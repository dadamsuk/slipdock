defmodule SlipdockWeb.PauseLiveTest do
  @moduledoc """
  The brake in the web app (#1116): Pause in the Runners panel for the
  whole tree and for each pool, each asking for a reason first; a banner on
  every board in the tree naming the root, with Resume for the owner; the
  held line in a card's jobs; and the automation WIP setting.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Boards, Repo, Runners}

  setup %{user: user} do
    user = user |> Ecto.Changeset.change(name: "David") |> Repo.update!()
    board = board_fixture(%{"name" => "Fleet"}, owner: user)
    [_backlog, todo, _doing, _done] = board.columns
    {:ok, runner, _} = Runners.create_runner(board, %{"name" => "laptop", "pool" => "dev"})
    %{user: user, board: board, todo: todo, runner: runner}
  end

  defp epic_board(parent_column, title) do
    {:ok, t} = Boards.find_template(nil, "Simple")
    epic = card_fixture(parent_column, %{"title" => title})
    {:ok, sub} = Boards.create_sub_board(epic, t)
    sub
  end

  test "pausing the whole tree needs a reason, then the banner shows and Resume lets it off",
       %{conn: conn, board: board} do
    {:ok, view, _} = live(conn, ~p"/boards/#{board}/automations")
    view |> element("#pause-tree") |> render_click()

    assert has_element?(view, "#pause-form", "Pause the whole tree")
    assert has_element?(view, "#pause-submit[disabled]")

    view |> form("#pause-form", %{"reason" => "   "}) |> render_change()
    assert has_element?(view, "#pause-submit[disabled]")

    view |> form("#pause-form", %{"reason" => "bad deploy"}) |> render_change()
    refute has_element?(view, "#pause-submit[disabled]")
    view |> form("#pause-form", %{"reason" => "bad deploy"}) |> render_submit()

    assert [%{pool: nil, reason: "bad deploy"}] = Runners.pauses(board)
    assert has_element?(view, "#runners-tree-paused", "paused by David: bad deploy")
    assert has_element?(view, "#resume-tree")

    {:ok, page, _} = live(conn, ~p"/boards/#{board}")
    assert has_element?(page, "[id^=pause-banner-]", "Paused on Fleet")
    assert has_element?(page, "[id^=pause-banner-]", "by David: bad deploy")

    page |> element("[id^=resume-pause-]") |> render_click()
    assert Runners.pauses(board) == []
    refute has_element?(page, "[id^=pause-banner-]")
  end

  test "a pool row has its own Pause, and Resume releases only that pool",
       %{conn: conn, board: board, user: user} do
    {:ok, _} = Runners.pause(board, %{"reason" => "freeze"}, user)

    {:ok, view, _} = live(conn, ~p"/boards/#{board}/automations")
    assert has_element?(view, "#runner-pool-dev")
    view |> element("#pause-pool-dev") |> render_click()
    assert has_element?(view, "#pause-form", "Pause pool dev")
    view |> form("#pause-form", %{"reason" => "flaky box"}) |> render_submit()

    assert has_element?(view, "#runner-pool-dev", "paused by David: flaky box")
    view |> element("#resume-pool-dev") |> render_click()

    # The tree's pause is still there; only the pool's went.
    assert [%{pool: nil, reason: "freeze"}] = Runners.pauses(board)
    assert has_element?(view, "#pause-pool-dev")
  end

  test "the banner shows on a sibling sub-board and names the root",
       %{conn: conn, board: board, todo: todo, user: user} do
    one = epic_board(todo, "Epic one")
    two = epic_board(todo, "Epic two")
    {:ok, _} = Runners.pause(one, %{"pool" => "dev", "reason" => "bad deploy"}, user)

    {:ok, page, _} = live(conn, ~p"/boards/#{two}")
    assert has_element?(page, "[id^=pause-banner-]", "Paused on Fleet")
    assert has_element?(page, "[id^=pause-banner-]", "pool dev")
    assert [%{root_board_id: root}] = Runners.pauses(two)
    assert root == board.id
  end

  test "someone the board is shared with sees the banner but no Resume or Pause",
       %{board: board, user: user} do
    {:ok, _} = Runners.pause(board, %{"reason" => "bad deploy"}, user)
    editor = user_fixture("editor#{System.unique_integer([:positive])}@example.com")
    share_fixture(board, [editor], "write")
    conn = log_in_user(build_conn(), editor)

    {:ok, page, _} = live(conn, ~p"/boards/#{board}")
    assert has_element?(page, "[id^=pause-banner-]", "bad deploy")
    refute has_element?(page, "[id^=resume-pause-]")

    # Even sent by hand, the event is the owner's.
    render_hook(page, "resume_pause", %{})
    assert [_] = Runners.pauses(board)
  end

  test "a queued job's held line shows in the card's jobs",
       %{conn: conn, board: board, todo: todo, user: user} do
    card = card_fixture(todo, %{"title" => "Held one"})
    {:ok, job} = Runners.queue(card, %{pool: "dev", kind: "claude", prompt: "go"})
    {:ok, _} = Runners.pause(board, %{"pool" => "dev", "reason" => "bad deploy"}, user)

    {:ok, view, _} = live(conn, ~p"/boards/#{board}/cards/#{card.id}")
    assert has_element?(view, "#card-job-held-#{job.id}", "Held: paused by David: bad deploy")
  end

  test "the automation WIP setting is off by default and the owner can turn it on",
       %{conn: conn, board: board} do
    {:ok, settings, _} = live(conn, ~p"/boards/#{board}/settings")
    assert has_element?(settings, "#board-automation-wip")
    refute has_element?(settings, "#board-automation-wip[checked]")

    settings |> form("#board-form", board: %{"automation_wip" => "true"}) |> render_submit()
    assert Boards.get_board!(board.id).automation_wip
  end
end
