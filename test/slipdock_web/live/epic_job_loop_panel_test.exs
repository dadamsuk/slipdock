defmodule SlipdockWeb.EpicJobLoopPanelTest do
  @moduledoc """
  The card panel of a subcard its epic's job is working (#2899): where the
  reporter saw "no runner". The subcard the job's step names shows the
  job's loop chip beside its assignees; a sibling it doesn't name, and the
  named one once the job has ended, show none.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Boards, Runners}
  alias Slipdock.Runners.Job

  setup %{conn: conn} do
    user = user_fixture()
    board = board_fixture(%{"name" => "Epic job panel"}, owner: user)
    [_backlog, _todo, doing, _done] = board.columns
    {:ok, runner, _} = Runners.create_runner(board, %{"name" => "dedev", "pool" => "dev"})

    epic = card_fixture(doing, %{"title" => "Epic"})
    {:ok, t} = Boards.Templates.find_template(nil, "Simple")
    {:ok, sub} = sub_board(epic, t)
    sub = Boards.get_board!(sub.id)
    sub_doing = Enum.find(sub.columns, &(&1.name == "Doing"))
    named = card_fixture(sub_doing, %{"title" => "Named"})
    sibling = card_fixture(sub_doing, %{"title" => "Sibling"})

    {:ok, _} = Runners.queue(epic, %{pool: "dev", kind: "claude", prompt: "go"})
    %Job{} = job = Runners.claim(runner)
    {:ok, :ok} = Runners.heartbeat(runner, job.id, nil, step: "##{named.id} CI running")

    %{
      conn: log_in_user(conn, user),
      runner: runner,
      epic: epic,
      board: board,
      sub: sub,
      named: named,
      sibling: sibling,
      job: job
    }
  end

  test "the named subcard's panel shows the epic job's loop chip", ctx do
    {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.sub}/cards/#{ctx.named.id}")

    assert has_element?(
             view,
             "#card-assignees #card-assignee-loop[data-loop-job='#{ctx.job.id}']",
             "dedev · build"
           )
  end

  test "a sibling the step doesn't name shows no chip", ctx do
    {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.sub}/cards/#{ctx.sibling.id}")

    assert has_element?(view, "#card-assignees")
    refute has_element?(view, "#card-assignee-loop")
    refute has_element?(view, "#card-assignees [data-loop-job]")
  end

  test "the epic's own panel shows its own job's chip", ctx do
    {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/cards/#{ctx.epic.id}")

    assert has_element?(
             view,
             "#card-assignee-loop[data-loop-job='#{ctx.job.id}']",
             "dedev · build"
           )
  end

  test "the chip goes from the named subcard's panel when the epic's job ends", ctx do
    {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.sub}/cards/#{ctx.named.id}")
    assert has_element?(view, "#card-assignee-loop")

    {:ok, _} = Runners.finish(ctx.runner, ctx.job.id, %{exit: 0})
    send(view.pid, {:jobs_changed, ctx.named.id})

    assert has_element?(view, "#card-assignees")
    refute has_element?(view, "#card-assignee-loop")
  end
end
