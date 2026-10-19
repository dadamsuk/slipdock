defmodule Slipdock.DoraTest do
  @moduledoc """
  A board's DORA report (#1134, `Slipdock.Dora`) against hand-built
  deploys: each metric, empty windows, one deploy, all failed, the
  percentiles, every band threshold, idea to production, the window before
  and the switch.
  """
  use Slipdock.DataCase, async: true

  import Ecto.Query
  import Slipdock.Fixtures

  alias Slipdock.{Actor, Boards, Deployments, Dora, Repo}
  alias Slipdock.Boards.{Card, CardMove}

  @now ~U[2026-10-19 12:00:00.000000Z]

  setup do
    user = user_fixture()
    board = board_fixture(%{"name" => "Delivery"}, owner: user)
    {:ok, board} = Boards.update_board(board, %{"delivery_metrics" => true})
    [_backlog, todo, doing, _done] = board.columns
    %{user: user, board: board, todo: todo, doing: doing}
  end

  defp ago(hours), do: DateTime.add(@now, -round(hours * 3600), :second)

  defp deploy!(board, hours_ago, attrs \\ %{}) do
    sha = :crypto.strong_rand_bytes(10) |> Base.encode16(case: :lower)

    {:ok, d} =
      Deployments.start(
        board,
        Map.merge(
          %{
            environment: "production",
            sha: sha,
            status: "succeeded",
            started_at: ago(hours_ago),
            finished_at: ago(hours_ago - 0.1)
          },
          attrs
        )
      )

    d
  end

  defp commit(hours_ago, subject \\ "work"),
    do: %{
      "sha" => :crypto.strong_rand_bytes(5) |> Base.encode16(case: :lower),
      "committed_at" => DateTime.to_iso8601(ago(hours_ago)),
      "subject" => subject
    }

  defp report!(board, opts \\ []) do
    {:ok, r} = Dora.for_board(board, Keyword.merge([now: @now], opts))
    r
  end

  test "off: no report at all", %{user: user} do
    board = board_fixture(%{"name" => "Off"}, owner: user)
    assert Dora.for_board(board) == {:error, :off}
  end

  test "an empty window has counts of nought and no percentiles or rates", %{board: board} do
    r = report!(board)
    assert r.enabled
    assert r.environment == "production"
    assert r.days == 30
    assert r.deployment_frequency == %{deploys: 0, per_day: 0.0, per_week: 0.0, band: nil}
    assert r.lead_time.p50 == nil
    assert r.lead_time.band == nil
    assert r.change_failure_rate.rate == nil
    assert r.time_to_restore == %{p50: nil, p85: nil, restores: 0, band: nil}
    assert r.rework_rate.rate == nil
    assert r.idea_to_production == %{p50: nil, p85: nil, cards: 0, from_created: 0}
    assert r.last_deploy == nil
    assert Dora.sentence(r) == "production, 30d: 0 deploys"
  end

  test "one deploy", %{board: board} do
    d = deploy!(board, 10, %{commits: [commit(12)], tag: "v1"})
    r = report!(board)

    assert r.deployment_frequency.deploys == 1
    assert r.deployment_frequency.band == "medium"
    # committed 12h ago, finished 9.9h ago.
    assert r.lead_time.p50 == round(2.1 * 3600)
    assert r.lead_time.commits == 1
    assert r.lead_time.band == "elite"
    assert r.change_failure_rate == %{failed: 0, deploys: 1, rate: 0.0, band: "elite"}
    assert r.last_deploy.id == d.id
    assert r.last_deploy.tag == "v1"
  end

  test "all failed", %{board: board} do
    deploy!(board, 30, %{status: "failed"})
    deploy!(board, 20, %{status: "failed"})
    r = report!(board)

    assert r.deployment_frequency.deploys == 0
    assert r.change_failure_rate == %{failed: 2, deploys: 2, rate: 1.0, band: "low"}
    assert r.time_to_restore.restores == 0
  end

  test "a started deploy counts nowhere yet", %{board: board} do
    {:ok, _} = Deployments.start(board, %{environment: "production", sha: "abcdef12"})
    r = report!(board, now: DateTime.add(DateTime.utc_now(), 60))
    assert r.deployment_frequency.deploys == 0
    assert r.change_failure_rate.deploys == 0
  end

  test "lead time P50/P85 over every commit shipped", %{board: board} do
    # Lead times 1h, 2h, 3h, 4h, 5h (finish is 0.1h after start).
    deploy!(board, 10.1, %{commits: [commit(11), commit(12)]})
    deploy!(board, 20.1, %{commits: [commit(23), commit(24), commit(25)]})
    r = report!(board)

    assert r.lead_time.commits == 5
    assert r.lead_time.p50 == 3 * 3600
    # percentile_cont(0.85) of 1..5h = 4.4h
    assert r.lead_time.p85 == round(4.4 * 3600)
  end

  test "change failure rate and time to restore", %{board: board} do
    deploy!(board, 50)
    deploy!(board, 40, %{status: "failed"})
    deploy!(board, 39)
    deploy!(board, 30)
    r = report!(board)

    assert r.change_failure_rate == %{failed: 1, deploys: 4, rate: 0.25, band: "low"}
    assert r.time_to_restore.restores == 1
    assert r.time_to_restore.p50 == 3600
    assert r.time_to_restore.band == "high"
  end

  test "rework counts deploys naming an incident card", %{board: board, todo: todo} do
    tag = tag_fixture(board, "incident")
    card = card_fixture(todo, %{"title" => "Down"})
    {:ok, _} = Boards.toggle_card_tag(card, tag)

    deploy!(board, 100)
    deploy!(board, 50, %{commits: [commit(51, "fix ##{card.id}")]})
    r = report!(board)

    assert r.rework_rate == %{rework: 1, deploys: 2, rate: 0.5}
    assert Dora.sentence(r) =~ "50% rework"
  end

  test "idea to production: first doing entry to first deploy naming the card", %{
    board: board,
    todo: todo,
    doing: doing,
    user: user
  } do
    card = card_fixture(todo, %{"title" => "Idea"})
    :ok = Boards.move_card(card.id, doing.id, nil, actor: Actor.web(user))

    Repo.update_all(
      from(m in CardMove, where: m.card_id == ^card.id and m.to_category == "doing"),
      set: [inserted_at: ago(48)]
    )

    made = card_fixture(todo, %{"title" => "Never started"})

    Repo.update_all(from(c in Card, where: c.id == ^made.id),
      set: [inserted_at: DateTime.truncate(ago(24), :second)]
    )

    deploy!(board, 12.1, %{commits: [commit(13, "ship ##{card.id} and ##{made.id}")]})
    # Shipped again later: still the first deploy that counts.
    deploy!(board, 2.1, %{commits: [commit(3, "more ##{card.id}")]})

    r = report!(board)
    assert r.idea_to_production.cards == 2
    assert r.idea_to_production.from_created == 1
    # 48h - 12h = 36h; 24h - 12h = 12h.
    assert r.idea_to_production.p50 == 24 * 3600
    assert Dora.sentence(r) =~ "idea to production 1d"
  end

  test "a card first shipped before the window isn't counted in it", %{board: board, todo: todo} do
    card = card_fixture(todo, %{"title" => "Old news"})
    deploy!(board, 40 * 24, %{commits: [commit(40 * 24 + 1, "##{card.id}")]})
    deploy!(board, 5, %{commits: [commit(6, "again ##{card.id}")]})
    assert report!(board).idea_to_production.cards == 0
  end

  test "the window before, and the trend in the sentence", %{board: board} do
    deploy!(board, 40 * 24)
    deploy!(board, 10)
    deploy!(board, 5)
    r = report!(board)

    assert r.previous.deployment_frequency.deploys == 1
    assert r.deployment_frequency.deploys == 2
    assert Dora.sentence(r) =~ "2 deploys ↑"
  end

  test "days and environment", %{board: board} do
    deploy!(board, 5)
    deploy!(board, 3 * 24)
    deploy!(board, 4, %{environment: "staging"})

    assert report!(board, days: 1).deployment_frequency.deploys == 1
    assert report!(board, days: "7").deployment_frequency.deploys == 2
    assert report!(board, days: 0).days == 1
    assert report!(board, days: 10_000).days == 365
    assert report!(board, days: "soon").days == 30

    r = report!(board, environment: "staging")
    assert r.deployment_frequency.deploys == 1
    assert r.environments == ["production", "staging"]
  end

  test "with no production, the environment deployed to most", %{board: board} do
    deploy!(board, 4, %{environment: "live"})
    deploy!(board, 3, %{environment: "live"})
    deploy!(board, 2, %{environment: "qa"})
    assert report!(board).environment == "live"
  end

  test "percentiles" do
    assert Dora.percentiles([]) == %{p50: nil, p85: nil}
    assert Dora.percentiles([7]) == %{p50: 7, p85: 7}
    assert Dora.percentiles([10, 0]) == %{p50: 5, p85: 9}
  end

  test "band thresholds" do
    assert Dora.frequency_band(1.0) == "elite"
    assert Dora.frequency_band(0.99) == "high"
    assert Dora.frequency_band(1 / 7) == "high"
    assert Dora.frequency_band(0.14) == "medium"
    assert Dora.frequency_band(1 / 30) == "medium"
    assert Dora.frequency_band(0.03) == "low"
    assert Dora.frequency_band(0.0) == nil

    day = 86_400
    assert Dora.lead_time_band(day - 1) == "elite"
    assert Dora.lead_time_band(day) == "high"
    assert Dora.lead_time_band(7 * day) == "medium"
    assert Dora.lead_time_band(30 * day) == "low"
    assert Dora.lead_time_band(nil) == nil

    assert Dora.failure_band(0.05) == "elite"
    assert Dora.failure_band(0.051) == "high"
    assert Dora.failure_band(0.10) == "high"
    assert Dora.failure_band(0.15) == "medium"
    assert Dora.failure_band(0.16) == "low"
    assert Dora.failure_band(nil) == nil

    assert Dora.restore_band(3599) == "elite"
    assert Dora.restore_band(3600) == "high"
    assert Dora.restore_band(day) == "medium"
    assert Dora.restore_band(7 * day) == "low"
    assert Dora.restore_band(nil) == nil
  end
end
