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
    assert has_element?(view, "#{row} [data-role=acceptor]", "accepted by agent “verifier”")
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

    assert has_element?(view, "#ledger-#{epic.id} [data-role=acceptor]", "not verified")
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
end
