defmodule SlipdockWeb.LedgerLiveTest do
  @moduledoc """
  The board's Ledger page (#1948): it shows what the API lists, grouped by
  day, with each line's events, acceptor, audit, evidence, missed `should`
  rules, PR, deploy, lead time and an epic's rollup; `since` is kept in the
  URL and a bad one is said in a callout; "Look closer" opens the card at its
  chat; a reader may look, a stranger is sent away; the Runners panel links
  to it beside Health and Findings.
  """
  use SlipdockWeb.ConnCase, async: true

  import Ecto.Query
  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Access, Boards, Repo}
  alias Slipdock.Boards.{Card, Comment}
  alias Slipdock.Deployments.Deployment
  alias SlipdockWeb.LedgerLive.Index

  setup %{user: owner} do
    board = board_fixture(%{"name" => "Shipping"}, owner: owner)
    done = List.last(board.columns)
    %{board: board, done: done, owner: owner}
  end

  defp hours_ago(h), do: DateTime.add(DateTime.utc_now(:second), -h * 3600, :second)

  defp shipped!(column, attrs, fields) do
    card = card_fixture(column, attrs)

    Repo.update_all(from(c in Card, where: c.id == ^card.id),
      set: Keyword.merge([completed: true, completed_at: hours_ago(1)], fields)
    )

    Repo.get!(Card, card.id)
  end

  test "lists each line with its evidence, and Look closer opens the card at its chat", ctx do
    card =
      shipped!(ctx.done, %{"title" => "Ledger page"},
        verify_state: "accepted",
        verify_at: hours_ago(1),
        verify_by: %{"kind" => "agent", "agent" => "verifier", "via" => "cli"},
        evidence: "Built the page\nmore",
        evidence_pr: "https://github.com/example/repo/pull/9",
        verify_checks: %{
          "rules" => [%{"id" => "UX-4", "result" => "broken", "severity" => "should"}]
        }
      )

    Repo.insert!(%Comment{card_id: card.id, body: "**Audit: disagrees** with the acceptance."})

    Repo.insert!(%Deployment{
      board_id: ctx.board.id,
      environment: "production",
      sha: "abc1234def",
      status: "succeeded",
      started_at: DateTime.utc_now(),
      finished_at: DateTime.utc_now(),
      card_ids: [card.id]
    })

    {:ok, view, html} = live(ctx.conn, ~p"/boards/#{ctx.board}/ledger")

    assert html =~ "Ledger"
    row = "#ledger-#{card.id}"
    assert has_element?(view, "#{row} [data-role=title]", "Ledger page")
    assert has_element?(view, "#{row} [data-role=event]", "accepted")
    assert has_element?(view, "#{row} [data-role=event]", "deployed")
    assert has_element?(view, "#{row} [data-role=acceptor]", "Accepted by agent “verifier”")
    assert has_element?(view, "#{row} [data-role=audit]", "audit disagrees")
    assert has_element?(view, "#{row} [data-role=evidence]", "Built the page")
    refute has_element?(view, "#{row} [data-role=evidence]", "more")
    assert has_element?(view, "#{row} [data-role=should]", "UX-4")

    assert has_element?(
             view,
             ~s(#{row} [data-role=pr][href="https://github.com/example/repo/pull/9"])
           )

    assert has_element?(view, "#{row} [data-role=deploy]", "deployed to production (abc1234)")

    assert has_element?(
             view,
             ~s(#ledger-look-#{card.id}[href="/boards/#{ctx.board.id}/cards/#{card.id}#card-ai-#{card.id}"]),
             "Look closer"
           )

    today = Date.utc_today() |> Date.to_iso8601()
    yesterday = Date.utc_today() |> Date.add(-1) |> Date.to_iso8601()

    assert has_element?(view, "#ledger-day-#{today} #{row}") or
             has_element?(view, "#ledger-day-#{yesterday} #{row}")
  end

  test "an unverified card says so, and an epic shows its subcards' rollup", ctx do
    epic = shipped!(ctx.done, %{"title" => "Epic"}, [])
    {:ok, t} = Boards.find_template(nil, "Simple")
    {:ok, sub} = sub_board(epic, t)
    [first | _] = Boards.get_board!(sub.id).columns
    sub_card = shipped!(first, %{"title" => "Child"}, [])
    _open = card_fixture(first, %{"title" => "Open child"})

    {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/ledger")

    assert has_element?(view, "#ledger-#{epic.id} [data-role=acceptor]", "Not verified")
    assert has_element?(view, "#ledger-#{epic.id} [data-role=subcards]", "1/2 subcards · 1 here")
    assert has_element?(view, "#ledger-#{sub_card.id}", "Child")
    assert has_element?(view, ~s(#ledger-look-#{sub_card.id}[href^="/boards/#{sub.id}/cards/"]))
  end

  test "since is kept in the URL, and a bad one is said in a callout", ctx do
    old = shipped!(ctx.done, %{"title" => "Last week"}, completed_at: hours_ago(24 * 5))

    {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/ledger")
    assert has_element?(view, "#ledger-empty")
    refute has_element?(view, "#ledger-#{old.id}")

    view |> form("#ledger-since", ledger: %{since: "7"}) |> render_change()
    assert_patch(view, "/boards/#{ctx.board.id}/ledger?since=7")
    assert has_element?(view, "#ledger-#{old.id}")

    {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/ledger?since=soon")
    assert has_element?(view, "#ledger-since-error", "since is a date")
    assert has_element?(view, "#ledger-empty")

    view |> form("#ledger-since", ledger: %{since: ""}) |> render_change()
    assert_patch(view, "/boards/#{ctx.board.id}/ledger")
  end

  test "a reader may look; a stranger is sent away", ctx do
    card = shipped!(ctx.done, %{"title" => "Seen"}, [])
    reader = user_fixture("ledger-live-reader@example.com")
    {:ok, _} = Access.grant(ctx.board, reader, "read", ctx.owner)

    {:ok, view, _} = live(conn_as(reader), ~p"/boards/#{ctx.board}/ledger")
    assert has_element?(view, "#ledger-#{card.id}")

    stranger = user_fixture("ledger-live-stranger@example.com")
    assert {:error, {_, %{to: "/"}}} = live(conn_as(stranger), ~p"/boards/#{ctx.board}/ledger")
  end

  test "the board's Runners panel links to it beside Health and Findings", ctx do
    {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/automations")

    assert has_element?(
             view,
             ~s(#runners-ledger[href="/boards/#{ctx.board.id}/ledger"]),
             "Ledger"
           )

    assert has_element?(view, "#runners-findings")
    assert has_element?(view, "#runners-health")
  end

  test "durations read short" do
    assert Index.duration(42) == "42s"
    assert Index.duration(150) == "2m"
    assert Index.duration(3 * 3600 + 120) == "3h 2m"
    assert Index.duration(2 * 86_400 + 5 * 3600) == "2d 5h"
  end

  describe "the drawing (#2013)" do
    test "segments keep the phases' order, each with its share and its tooltip's side" do
      segs = Index.segments(%{deploy: 600, build: 1800, ci: 600, backlog: 0})

      assert Enum.map(segs, & &1.phase) == [:build, :ci, :deploy]
      assert Enum.map(segs, & &1.share) == [60.0, 20.0, 20.0]
      assert Enum.map(segs, & &1.align) == ["start", "end", "end"]
      assert Index.segments(%{}) == []
    end

    test "a bar's length is its lead time on a log scale, a minute to 30 days" do
      assert Index.bar_width(60) == 4.0
      assert Index.bar_width(10) == 4.0
      assert Index.bar_width(3600) == 38.4
      assert Index.bar_width(86_400) == 68.1
      assert Index.bar_width(30 * 86_400) == 100.0
      assert Index.bar_width(90 * 86_400) == 100.0
      assert Index.bar_width(nil) == 0.0
      # Ten minutes and three days both read: neither a sliver nor the whole track.
      assert Index.bar_width(600) > 15 and Index.bar_width(3 * 86_400) < 85
    end

    test "a day's summary counts the lines, takes the median and adds the phases up" do
      items = [
        %{lead_time: %{seconds: 3600, phases: %{build: 3000, ci: 600}}},
        %{lead_time: %{seconds: 600, phases: %{build: 600}}},
        %{lead_time: %{seconds: 7200, phases: %{waiting_on_person: 7200}}},
        %{lead_time: %{seconds: 0, phases: %{}}}
      ]

      assert Index.day_summary(items) == %{
               count: 4,
               median: 3600,
               phases: %{build: 3600, ci: 600, waiting_on_person: 7200}
             }

      assert Index.median([]) == nil
      assert Index.median([10, 2, 4, 8]) == 6
    end

    test "waiting phases are the hatched ones" do
      assert Index.waiting?(:waiting_on_person) and Index.waiting?(:backlog)
      refute Index.waiting?(:build) or Index.waiting?(:unexplained)
    end

    test "a line draws its phases, the total beside them, and the day says what shipped", ctx do
      card =
        shipped!(ctx.done, %{"title" => "Timed"},
          inserted_at: hours_ago(5) |> DateTime.to_naive()
        )

      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/ledger")
      bar = "#ledger-bar-#{card.id}"
      assert has_element?(view, bar)
      assert has_element?(view, "#ledger-#{card.id} [data-role=total]", "4h")

      html = view |> element(bar) |> render()

      shares =
        Regex.scan(~r/data-share="([\d.]+)"/, html)
        |> Enum.map(fn [_, x] -> String.to_float(x) end)

      assert shares != []
      assert_in_delta Enum.sum(shares), 100.0, 0.5
      assert html =~ ~r/data-tip="[^"]+ · 4h \d+m · [\d.]+%"/

      assert has_element?(view, "[data-role=day-count]", "1 shipped")
      assert has_element?(view, "[data-role=day-median]", "4h")
      assert has_element?(view, "[id^=ledger-day-bar-] [data-phase]")
    end

    test "a line with no timings says so and draws no bar", ctx do
      at = hours_ago(1)

      card =
        shipped!(ctx.done, %{"title" => "Instant"},
          completed_at: at,
          inserted_at: DateTime.to_naive(at)
        )

      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/ledger")
      assert has_element?(view, "#ledger-#{card.id} [data-role=no-timings]")
      refute has_element?(view, "#ledger-bar-#{card.id}")
    end

    test "the key names every phase, once there is something to show", ctx do
      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/ledger")
      refute has_element?(view, "#ledger-legend")

      shipped!(ctx.done, %{"title" => "Any"}, [])
      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/ledger")

      for phase <- Slipdock.LeadTime.phases(),
          do: assert(has_element?(view, ~s(#ledger-legend [data-phase="#{phase}"])))

      assert has_element?(view, ~s(#ledger-legend [data-phase="waiting_on_person"]), "(waiting)")
      assert has_element?(view, "#ledger-legend", "log scale")
    end

    test "a merge links its commit beside the pull request", ctx do
      card =
        shipped!(ctx.done, %{"title" => "Merged"},
          evidence_pr: "https://github.com/example/repo/pull/12",
          merge_sha: "fedcba9876543"
        )

      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/ledger")
      assert has_element?(view, "#ledger-#{card.id} [data-role=pr]", "Pull request #12")

      assert has_element?(
               view,
               ~s(#ledger-#{card.id} [data-role=merge] a[href="https://github.com/example/repo/commit/fedcba9876543"]),
               "fedcba9"
             )
    end

    test "a day's heading is a section title, and a line's time is a timestamp", ctx do
      card = shipped!(ctx.done, %{"title" => "Titled"}, [])
      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/ledger")

      assert has_element?(view, ".ledger-day-head h2.section-title")
      assert has_element?(view, "#ledger-#{card.id} time[datetime][title]")
    end
  end
end
