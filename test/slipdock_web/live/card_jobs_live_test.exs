defmodule SlipdockWeb.CardJobsLiveTest do
  # The card's "Runner jobs" section: there only when a rule has sent the
  # card to a runner, kept up to date as the runner reports, and a way to
  # stop a job for whoever can edit the card.
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Repo, Runners}
  alias Slipdock.Runners.Job

  setup %{user: user} do
    board = board_fixture(%{"name" => "Agents"}, owner: user)
    card = card_fixture(hd(board.columns), %{"title" => "Fix it"})
    {:ok, runner, _} = Runners.create_runner(board, %{"name" => "laptop", "pool" => "dev"})
    %{board: board, card: card, runner: runner}
  end

  defp queue(card), do: Runners.queue(card, %{pool: "dev", kind: "claude", prompt: "go"})

  test "a card no rule has sent anywhere has no jobs section", %{
    conn: conn,
    board: board,
    card: card
  } do
    {:ok, _view, html} = live(conn, ~p"/boards/#{board}/cards/#{card}")
    refute html =~ "Runner jobs"
  end

  test "shows each job and follows the runner as it reports", ctx do
    {:ok, job} = queue(ctx.card)
    {:ok, view, html} = live(ctx.conn, ~p"/boards/#{ctx.board}/cards/#{ctx.card}")
    assert html =~ "Runner jobs"
    assert has_element?(view, "#card-job-#{job.id}", "queued")

    Runners.claim(ctx.runner)
    Runners.heartbeat(ctx.runner, job.id, "compiling…\nrunning tests")
    render(view)
    assert render(view) =~ "running tests"
    assert has_element?(view, "#card-job-#{job.id}", "laptop")

    Runners.finish(ctx.runner, job.id, %{exit: "1", output: "2 tests failed"})
    # The broadcast reaches the board, which then updates the card panel:
    # one render to let the first land, the next sees the second.
    render(view)
    assert has_element?(view, "#card-job-#{job.id}", "failed")
    assert render(view) =~ "2 tests failed"
    refute has_element?(view, "#card-job-#{job.id} button", "Cancel")
  end

  test "cancel stops a queued job, and asks a running one to stop", ctx do
    {:ok, queued} = queue(ctx.card)
    {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/cards/#{ctx.card}")

    view |> element("#card-job-#{queued.id} button", "Cancel") |> render_click()
    assert Repo.get!(Job, queued.id).status == "cancelled"
    assert has_element?(view, "#card-job-#{queued.id}", "cancelled")

    {:ok, running} = queue(ctx.card)
    Runners.claim(ctx.runner)
    # As above: one render lets the broadcasts land, the next sees the panel
    # they updated. Clicking straight away can look for a row not there yet.
    render(view)
    assert has_element?(view, "#card-job-#{running.id}", "laptop")
    view |> element("#card-job-#{running.id} button", "Cancel") |> render_click()
    assert Repo.get!(Job, running.id).cancel_requested_at
    assert has_element?(view, "#card-job-#{running.id}", "stopping")
  end

  test "somebody with read access sees the jobs but can't cancel them", ctx do
    {:ok, job} = queue(ctx.card)
    reader = user_fixture("reader#{System.unique_integer([:positive])}@example.com")
    share_fixture(ctx.board, [reader], "read")

    {:ok, view, _} =
      live(log_in_user(build_conn(), reader), ~p"/boards/#{ctx.board}/cards/#{ctx.card}")

    assert has_element?(view, "#card-job-#{job.id}")
    refute has_element?(view, "#card-job-#{job.id} button", "Cancel")

    render_click(with_target(view, "#board-card"), "cancel_job", %{"job" => to_string(job.id)})
    assert Repo.get!(Job, job.id).status == "queued"
  end
end
