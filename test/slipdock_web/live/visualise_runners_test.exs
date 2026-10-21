defmodule SlipdockWeb.VisualiseRunnersTest do
  @moduledoc "The Visualise page's Agentic runners section (#1193)."
  use SlipdockWeb.ConnCase, async: true

  import Ecto.Query
  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Repo, Runners}
  alias Slipdock.Runners.{Job, Runner}

  setup %{user: user} do
    board = board_fixture(%{"name" => "Agents"}, owner: user)
    [_backlog, todo, doing, _done] = board.columns
    {:ok, runner, _} = Runners.create_runner(board, %{"name" => "dev-box", "pool" => "dev"})
    %{board: board, todo: todo, doing: doing, runner: runner}
  end

  defp job(ctx, status, minutes_ago, took_minutes, attrs \\ %{}) do
    card = attrs[:card] || card_fixture(ctx.todo, %{"title" => attrs[:title] || "Job card"})
    claimed = DateTime.add(DateTime.utc_now(:second), -minutes_ago * 60)

    Repo.insert!(
      struct!(
        Job,
        Map.merge(
          %{
            pool: "dev",
            kind: "claude",
            prompt: "go",
            status: status,
            board_id: ctx.board.id,
            root_board_id: ctx.board.id,
            card_id: card.id,
            runner_id: ctx.runner.id,
            claimed_at: claimed,
            finished_at: took_minutes && DateTime.add(claimed, took_minutes * 60)
          },
          Map.drop(attrs, [:card, :title])
        )
      )
    )
  end

  defp seen(ctx, current \\ nil) do
    Repo.update_all(from(r in Runner, where: r.id == ^ctx.runner.id),
      set: [last_seen_at: DateTime.utc_now(:second), current_job_id: current]
    )
  end

  test "no runners: one line, and the way to set one up", %{conn: conn, user: user} do
    quiet = board_fixture(%{"name" => "Quiet"}, owner: user)
    {:ok, view, _} = live(conn, ~p"/boards/#{quiet}/visualise")
    assert has_element?(view, "#runners-empty", "No runners take work from this board.")
    assert has_element?(view, ~s|#runners-empty a[href="/boards/#{quiet.id}/automations"]|)
  end

  test "an idle runner, its numbers and a bar with every outcome", %{conn: conn} = ctx do
    seen(ctx)
    job(ctx, "done", 120, 10)
    job(ctx, "done", 100, 20)
    job(ctx, "parked", 90, 5)
    job(ctx, "failed", 80, 1)

    {:ok, view, _} = live(conn, ~p"/boards/#{ctx.board}/visualise")
    assert has_element?(view, ~s|#runner-#{ctx.runner.id}[data-status="idle"]|)
    assert has_element?(view, "#runner-#{ctx.runner.id}-status", "Idle")
    refute has_element?(view, "#runner-#{ctx.runner.id}-current")
    assert has_element?(view, "#runner-#{ctx.runner.id}-success", "50%")
    assert has_element?(view, "#runner-#{ctx.runner.id}", "2 done")
    assert has_element?(view, "#runner-#{ctx.runner.id}", "0 running")

    # Zeros take no room; the rest share the bar by their counts.
    assert has_element?(
             view,
             ~s|#runner-#{ctx.runner.id}-outcomes [data-outcome="done"][style="width: 50.0%"]|
           )

    assert has_element?(
             view,
             ~s|#runner-#{ctx.runner.id}-outcomes [data-outcome="parked"][style="width: 25.0%"]|
           )

    refute has_element?(view, ~s|#runner-#{ctx.runner.id}-outcomes [data-outcome="running"]|)

    assert has_element?(
             view,
             ~s|#runner-#{ctx.runner.id}-outcomes[aria-label="Outcomes: 2 done, 1 parked, 1 failed, 0 running"]|
           )
  end

  test "a running runner shows its job against the median", %{conn: conn} = ctx do
    job(ctx, "done", 300, 20)
    card = card_fixture(ctx.doing, %{"title" => "Being built"})
    running = job(ctx, "running", 10, nil, %{card: card})
    seen(ctx, running.id)

    {:ok, view, _} = live(conn, ~p"/boards/#{ctx.board}/visualise")
    assert has_element?(view, "#runner-#{ctx.runner.id}-status", "Running")

    assert has_element?(
             view,
             "#runner-#{ctx.runner.id}-current",
             "Job ##{running.id} · card ##{card.id}"
           )

    assert has_element?(
             view,
             ~s|#runner-#{ctx.runner.id}-current a[href="/boards/#{ctx.board.id}/cards/#{card.id}"]|,
             "Being built"
           )

    assert has_element?(view, "#runner-#{ctx.runner.id}-current", "median job 20m 0s")
    assert has_element?(view, ~s|#runner-#{ctx.runner.id}-current [style="width: 50%"]|)
  end

  test "the recent jobs table: newest first, linked, outcomes in words, one duration scale",
       %{conn: conn} = ctx do
    seen(ctx)
    a = job(ctx, "done", 300, 40, %{title: "First"})
    b = job(ctx, "parked", 200, 10, %{title: "Second"})

    Repo.insert!(%Slipdock.Boards.Wait{card_id: b.card_id, job_id: b.id, needs: "Which colour?"})
    c = job(ctx, "failed", 100, 20, %{title: String.duplicate("A very long title ", 6)})

    {:ok, view, html} = live(conn, ~p"/boards/#{ctx.board}/visualise")
    order = Regex.scan(~r/id="job-(\d+)"/, html) |> Enum.map(fn [_, id] -> id end)
    assert order == Enum.map([c, b, a], &to_string(&1.id))

    assert has_element?(view, "#job-#{a.id}", "Done")
    assert has_element?(view, "#job-#{b.id}", "Parked: Which colour?")
    assert has_element?(view, "#job-#{c.id}", "Failed")

    assert has_element?(
             view,
             ~s|#job-#{a.id} a[href="/boards/#{ctx.board.id}/cards/#{a.card_id}"]|,
             "First"
           )

    assert has_element?(view, "#job-#{c.id} a.truncate")
    assert has_element?(view, ~s|#job-#{a.id} [style="width: 100%"]|)
    assert has_element?(view, ~s|#job-#{b.id} [style="width: 25%"]|)
    assert has_element?(view, "#runners .overflow-x-auto #recent-jobs")
  end

  test "a job claimed or finished updates the section live", %{conn: conn} = ctx do
    seen(ctx)
    {:ok, view, _} = live(conn, ~p"/boards/#{ctx.board}/visualise")
    assert has_element?(view, "#runner-#{ctx.runner.id}-status", "Idle")

    running = job(ctx, "running", 1, nil)
    seen(ctx, running.id)

    Phoenix.PubSub.broadcast(
      Slipdock.PubSub,
      "runner_jobs:#{ctx.board.id}",
      {:jobs_changed, running.card_id}
    )

    # The broadcast schedules a refresh; let it fire now.
    _ = :sys.get_state(view.pid)
    send(view.pid, :refresh)

    assert has_element?(view, "#runner-#{ctx.runner.id}-status", "Running")
    assert has_element?(view, "#job-#{running.id}", "Running")
  end
end
