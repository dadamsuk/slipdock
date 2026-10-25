defmodule SlipdockWeb.VisualiseDoraTest do
  @moduledoc "The Visualise page's Delivery (DORA) section (#1194)."
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Boards, Deployments}
  alias SlipdockWeb.BoardLive.VisualiseComponents

  setup %{user: user} do
    board = board_fixture(%{"name" => "Ships"}, owner: user)
    %{board: board}
  end

  defp on(board) do
    {:ok, board} = Boards.update_board(board, %{"delivery_metrics" => true})
    board
  end

  defp at(hours), do: DateTime.add(DateTime.utc_now(), -round(hours * 3600), :second)

  defp deploy!(board, hours_ago, attrs \\ %{}) do
    {:ok, d} =
      Deployments.start(
        board,
        Map.merge(
          %{
            environment: "production",
            sha: :crypto.strong_rand_bytes(10) |> Base.encode16(case: :lower),
            status: "succeeded",
            started_at: at(hours_ago),
            finished_at: at(hours_ago - 0.1)
          },
          attrs
        )
      )

    d
  end

  defp commit(hours_ago),
    do: %{
      "sha" => :crypto.strong_rand_bytes(5) |> Base.encode16(case: :lower),
      "committed_at" => DateTime.to_iso8601(at(hours_ago)),
      "subject" => "work"
    }

  test "off: the nudge to turn delivery metrics on, and no numbers", %{conn: conn, board: board} do
    {:ok, view, _} = live(conn, ~p"/boards/#{board}/visualise")
    assert has_element?(view, "#dora-off", "Delivery metrics are off")
    assert has_element?(view, ~s|#dora-off a[href="/boards/#{board.id}/settings?tab=features"]|)
    assert has_element?(view, "#dora-off", "slipdock set-board #{board.code} --delivery-metrics")
    refute has_element?(view, "#dora-frequency")
  end

  test "on with no deploys yet: says how to record them", %{conn: conn, board: board} do
    board = on(board)
    {:ok, view, _} = live(conn, ~p"/boards/#{board}/visualise")
    assert has_element?(view, "#dora-no-deploys", "slipdock deploy run")
    refute has_element?(view, "#dora-frequency")
  end

  test "each metric card's value, detail and band", %{conn: conn, board: board} do
    board = on(board)
    for h <- 1..30, do: deploy!(board, h * 20, %{commits: [commit(h * 20 + 2)]})
    deploy!(board, 5, %{status: "failed", tag: "v9"})

    {:ok, view, _} = live(conn, ~p"/boards/#{board}/visualise")

    assert has_element?(view, ~s|#dora-frequency[data-band="elite"] [data-value]|, "1.0 a day")
    assert has_element?(view, "#dora-frequency", "30 deploys · 7.0 a week")
    assert has_element?(view, "#dora-frequency", "Elite: at least once a day")
    assert has_element?(view, ~s|#dora-lead-time[data-band="elite"] [data-value]|, "2h 6m")
    assert has_element?(view, "#dora-lead-time", "30 commits")
    assert has_element?(view, "#dora-cfr [data-value]", "3%")
    assert has_element?(view, "#dora-cfr", "1 failed of 31 deploys")
    assert has_element?(view, ~s|#dora-cfr[data-band="elite"]|)
    assert has_element?(view, "#dora-last-deploy", "Last deploy v9")
  end

  test "time to restore with no incidents says so, unscored", %{conn: conn, board: board} do
    board = on(board)
    deploy!(board, 10)

    {:ok, view, _} = live(conn, ~p"/boards/#{board}/visualise")
    assert has_element?(view, ~s|#dora-restore[data-band="none"] [data-value]|, "n/a")
    assert has_element?(view, "#dora-restore", "No incidents")
    assert has_element?(view, "#dora-restore", "Scored after the first incident.")
    refute has_element?(view, ~s|#dora-restore [data-filled="true"]|)
  end

  test "the band scale fills up to its band" do
    for {band, filled} <- [{"low", 1}, {"medium", 2}, {"high", 3}, {"elite", 4}] do
      html =
        render_component(&VisualiseComponents.dora_section/1,
          board: %{id: 1, code: "x"},
          cycle_p50: nil,
          dora: report(band)
        )

      [_, card] = String.split(html, ~s|id="dora-frequency"|, parts: 2)
      [card | _] = String.split(card, ~s|id="dora-lead-time"|, parts: 2)
      count = length(Regex.scan(~r/data-filled="true"/, card))
      assert count == filled, "#{band}: #{count}"
      assert html =~ ~s|data-band="#{band}"|
    end
  end

  test "deploys per day: bars with failures stacked", %{conn: conn, board: board} do
    board = on(board)
    deploy!(board, 3)
    deploy!(board, 2, %{status: "failed"})

    {:ok, view, _} = live(conn, ~p"/boards/#{board}/visualise")
    assert has_element?(view, "#chart-deploys", "2 deploys, 1 succeeded")
    assert has_element?(view, "#chart-deploys", "1 failed")
    assert has_element?(view, "#chart-deploys rect[data-failed]")

    assert has_element?(
             view,
             ~s|#chart-deploys svg[aria-label="Deploys per day: 2 deploys, 1 succeeded, 1 failed"]|
           )
  end

  test "no deploys before the window: says there's nothing to compare", %{
    conn: conn,
    board: board
  } do
    board = on(board)
    deploy!(board, 10)
    {:ok, view, _} = live(conn, ~p"/boards/#{board}/visualise")

    assert has_element?(
             view,
             "#dora",
             "no deploys recorded in the 30 days before, so no comparison yet"
           )

    refute has_element?(view, "#dora-frequency", "from")
  end

  test "with deploys before the window: the trend instead", %{conn: conn, board: board} do
    board = on(board)
    deploy!(board, 10)
    deploy!(board, 9)
    deploy!(board, 40 * 24)

    {:ok, view, _} = live(conn, ~p"/boards/#{board}/visualise")
    refute has_element?(view, "#dora", "so no comparison yet")
    assert has_element?(view, "#dora-frequency", "↑ from 1")
  end

  test "idea to production in its parts, rework and commits shipped", %{conn: conn, board: board} do
    board = on(board)
    deploy!(board, 10, %{commits: [commit(13), commit(12)]})
    deploy!(board, 5, %{commits: [commit(6)]})

    {:ok, view, _} = live(conn, ~p"/boards/#{board}/visualise")
    assert has_element?(view, "#itp-commit-deploy", "Commit to deploy")
    assert has_element?(view, "#itp-start-done", "–")
    assert has_element?(view, "#idea-to-production", "covers 0 cards")
    assert has_element?(view, "#dora-rework", "0 of 2 deploys")
    assert has_element?(view, "#dora-commits", "3")
    assert has_element?(view, "#dora-commits", "1.5 a deploy")
  end

  # A report with every metric in `band`, for the scale.
  defp report(band) do
    metric = %{p50: 60, p85: 60}
    today = Date.utc_today()

    %{
      environment: "production",
      days: 30,
      since: DateTime.utc_now(),
      until: DateTime.utc_now(),
      last_deploy: %{tag: "v1", sha: "abc", at: DateTime.utc_now()},
      deployment_frequency: %{deploys: 3, per_day: 0.1, per_week: 0.7, band: band},
      lead_time: Map.merge(metric, %{commits: 3, band: band}),
      change_failure_rate: %{failed: 0, deploys: 3, rate: 0.0, band: band},
      time_to_restore: Map.merge(metric, %{restores: 1, band: band}),
      rework_rate: %{rework: 0, deploys: 3, rate: 0.0},
      idea_to_production: %{p50: nil, p85: nil, cards: 0, from_created: 0},
      commits_per_deploy: 1.0,
      per_day: [%{date: today, succeeded: 3, failed: 0}],
      previous: %{
        deployment_frequency: %{deploys: 0},
        lead_time: %{p50: nil},
        change_failure_rate: %{rate: nil},
        time_to_restore: %{p50: nil}
      }
    }
  end
end
