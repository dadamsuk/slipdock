defmodule SlipdockWeb.ShippedLineTest do
  @moduledoc """
  A card's shipped lines (#1134): after a succeeded deploy names it, not a
  failed one; one per environment, latest first; marked when a rollback
  goes back past it; nothing with delivery metrics off; a card on a
  sub-board. Through `Slipdock.Deployments.shipped/1`, the card's API JSON,
  MCP get_card and the card panel, each with the date and time in the
  reader's zone (#2022), and a finished card's outcome.
  """
  use SlipdockWeb.ConnCase, async: true

  import Ecto.Query
  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Boards, Deployments}
  alias Slipdock.Deployments.Incidents

  setup %{conn: conn, user: user} do
    board = board_fixture(%{"name" => "Shipping"}, owner: user)
    {:ok, board} = Boards.update_board(board, %{"delivery_metrics" => true})
    [_backlog, todo | _] = board.columns
    card = card_fixture(todo, %{"title" => "Feature"})

    %{
      conn: conn,
      json: put_req_header(conn, "accept", "application/json"),
      board: board,
      card: card
    }
  end

  defp deploy!(board, card, at, attrs \\ %{}) do
    sha = Map.get(attrs, :sha, :crypto.strong_rand_bytes(10) |> Base.encode16(case: :lower))

    {:ok, d} =
      Deployments.start(
        board,
        Map.merge(
          %{
            environment: "production",
            sha: sha,
            status: "succeeded",
            started_at: at,
            finished_at: at,
            commits: if(card, do: [%{"sha" => sha, "subject" => "feat ##{card.id}"}], else: [])
          },
          attrs
        )
      )

    d
  end

  test "a succeeded deploy ships the card, a failed one doesn't", %{board: board, card: card} do
    deploy!(board, card, ~U[2026-10-18 09:00:00.000000Z], %{status: "failed"})
    assert Deployments.shipped(card) == []

    d = deploy!(board, card, ~U[2026-10-19 09:00:00.000000Z], %{tag: "v3"})
    assert [line] = Deployments.shipped(card)
    assert line.deployment_id == d.id
    refute line.rolled_back

    assert Deployments.shipped_text(line) ==
             "Shipped to production · #{String.slice(d.sha, 0, 7)} (v3) · 19 Oct 09:00"
  end

  test "one line per environment, latest first", %{board: board, card: card} do
    deploy!(board, card, ~U[2026-10-10 09:00:00.000000Z], %{environment: "staging"})
    deploy!(board, card, ~U[2026-10-12 09:00:00.000000Z], %{environment: "production"})
    deploy!(board, card, ~U[2026-10-14 09:00:00.000000Z], %{environment: "staging"})

    assert [
             %{environment: "staging", at: ~U[2026-10-14 09:00:00.000000Z]},
             %{environment: "production"}
           ] =
             Deployments.shipped(card)
  end

  test "a rollback past it is shown, and a later re-ship clears it", %{board: board, card: card} do
    before = deploy!(board, nil, ~U[2026-10-10 09:00:00.000000Z])
    deploy!(board, card, ~U[2026-10-11 09:00:00.000000Z])

    deploy!(board, nil, ~U[2026-10-12 09:00:00.000000Z], %{sha: before.sha, rollback: true})
    assert [%{rolled_back: true} = line] = Deployments.shipped(card)
    assert Deployments.shipped_text(line) =~ "rolled back since"

    deploy!(board, card, ~U[2026-10-13 09:00:00.000000Z])
    assert [%{rolled_back: false}] = Deployments.shipped(card)
  end

  test "nothing while the board's delivery metrics are off", %{
    board: board,
    card: card,
    json: conn
  } do
    deploy!(board, card, ~U[2026-10-19 09:00:00.000000Z])
    {:ok, _} = Boards.update_board(board, %{"delivery_metrics" => false})
    assert Deployments.shipped(card) == []

    body = conn |> get(~p"/api/cards/#{card.id}") |> json_response(200)
    refute Map.has_key?(body["card"], "shipped")
  end

  test "a card on a sub-board named by a commit", %{board: board, card: card} do
    {:ok, t} = Boards.find_template(nil, "Simple")
    {:ok, sub} = sub_board(card, t)
    [first | _] = Boards.get_board!(sub.id).columns
    child = card_fixture(first, %{"title" => "Child"})

    deploy!(board, child, ~U[2026-10-19 09:00:00.000000Z])
    assert [%{environment: "production"}] = Deployments.shipped(child)
  end

  test "the card's API JSON and MCP get_card carry it, and incident_of", %{
    conn: conn,
    json: json,
    board: board,
    card: card
  } do
    d = deploy!(board, card, ~U[2026-10-19 09:00:00.000000Z])
    {:ok, _} = Incidents.link(card, d.id)

    body = json |> get(~p"/api/cards/#{card.id}") |> json_response(200)

    assert [%{"environment" => "production", "sha" => sha, "text" => text}] =
             body["card"]["shipped"]

    assert sha == d.sha
    assert text =~ "Shipped to production"
    assert body["card"]["incident_of"] == d.id

    mcp =
      conn
      |> put_req_header("content-type", "application/json")
      |> post(
        "/mcp",
        Jason.encode!(%{
          jsonrpc: "2.0",
          id: 1,
          method: "tools/call",
          params: %{name: "get_card", arguments: %{card: card.id}}
        })
      )
      |> json_response(200)
      |> get_in(["result", "content"])
      |> hd()
      |> Map.fetch!("text")
      |> Jason.decode!()

    assert [%{"text" => ^text}] = mcp["shipped"]
    assert mcp["incident_of"] == d.id
  end

  # #2022: the time with the date, in the reader's zone, in every door.
  test "the line gives date and time, in the reader's zone", %{
    conn: conn,
    json: json,
    board: board,
    card: card,
    user: user
  } do
    at = ~U[2026-11-06 14:32:00.000000Z]
    d = deploy!(board, card, at)
    [line] = Deployments.shipped(card)
    short = String.slice(d.sha, 0, 7)

    assert Deployments.shipped_text(line) == "Shipped to production · #{short} · 6 Nov 14:32"

    assert Deployments.shipped_text(line, "America/New_York") ==
             "Shipped to production · #{short} · 6 Nov 09:32"

    user = Slipdock.Accounts.adopt_browser_timezone(user, "Asia/Tokyo")
    assert user.timezone == "Asia/Tokyo"
    expected = "Shipped to production · #{short} · 6 Nov 23:32"

    body = json |> get(~p"/api/cards/#{card.id}") |> json_response(200)
    assert [%{"text" => ^expected}] = body["card"]["shipped"]

    assert [%{"text" => ^expected}] = mcp_card(conn, card)["shipped"]

    {:ok, view, _} = live(conn, ~p"/boards/#{board}/cards/#{card.id}")
    assert has_element?(view, "#card-shipped", expected)
  end

  test "a finished card's API JSON and get_card carry its outcome, the old handoff folded", %{
    conn: conn,
    json: json,
    card: card
  } do
    {:ok, _} =
      Boards.leave_handoff(card, nil, %{next_step: "Accepting will merge it", via: "runner"})

    Slipdock.Repo.update_all(
      from(c in Slipdock.Boards.Card, where: c.id == ^card.id),
      set: [
        completed: true,
        completed_at: DateTime.add(DateTime.utc_now(:second), 60),
        verify_state: "accepted",
        verify_by: %{"kind" => "agent", "via" => "runner", "agent" => "verifier"},
        evidence_pr: "https://github.com/acme/app/pull/215",
        merge_sha: "def5678aa"
      ]
    )

    body = json |> get(~p"/api/cards/#{card.id}") |> json_response(200)
    outcome = body["card"]["outcome"]

    assert outcome["text"] =~
             ~r/^Done \d+ \w+ \d\d:\d\d · accepted by runner verifier · merged PR #215 \(def5678\)$/

    assert outcome["merge_sha"] == "def5678aa"
    assert body["card"]["handoff"] == nil

    assert %{"next_step" => "Accepting will merge it", "before_finish" => true} =
             body["card"]["last_handoff"]

    mcp = mcp_card(conn, card)
    assert mcp["outcome"]["text"] == outcome["text"]
    assert mcp["handoff"] == nil
    assert mcp["last_handoff"]["before_finish"]
  end

  test "an open card has no outcome, and keeps its handoff", %{json: json, card: card} do
    {:ok, _} = Boards.leave_handoff(card, nil, %{next_step: "Write the tests", via: "runner"})
    body = json |> get(~p"/api/cards/#{card.id}") |> json_response(200)
    refute Map.has_key?(body["card"], "outcome")
    assert body["card"]["handoff"]["next_step"] == "Write the tests"
  end

  defp mcp_card(conn, card) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post(
      "/mcp",
      Jason.encode!(%{
        jsonrpc: "2.0",
        id: 1,
        method: "tools/call",
        params: %{name: "get_card", arguments: %{card: card.id}}
      })
    )
    |> json_response(200)
    |> get_in(["result", "content"])
    |> hd()
    |> Map.fetch!("text")
    |> Jason.decode!()
  end

  test "the card panel shows it", %{conn: conn, board: board, card: card} do
    {:ok, view, _} = live(conn, ~p"/boards/#{board}/cards/#{card.id}")
    refute has_element?(view, "#card-shipped")

    deploy!(board, card, ~U[2026-10-19 09:00:00.000000Z])
    {:ok, view, _} = live(conn, ~p"/boards/#{board}/cards/#{card.id}")
    assert has_element?(view, "#card-shipped", "Shipped to production")
  end

  # #1669: deploys CI made while their record failed, backfilled from its
  # runs as `slipdock deploy backfill --from-runs` sends them.
  test "a backfilled deploy ships the cards its commits name, and twice is once", %{
    board: board,
    card: card
  } do
    at = ~U[2026-11-02 23:06:00.000000Z]
    sha = "8847df1a" <> String.duplicate("0", 32)

    attrs = %{
      "environment" => "production",
      "sha" => sha,
      "previous_sha" => String.duplicate("d", 40),
      "status" => "succeeded",
      "started_at" => at,
      "finished_at" => at,
      "source" => "backfill",
      "commits" => [%{"sha" => sha, "message" => "Merge PR 3: card ##{card.id}"}]
    }

    assert {:ok, d} = Deployments.start(board, attrs)
    assert d.card_ids == [card.id]
    assert [%{deployment_id: id, sha: ^sha}] = Deployments.shipped(card)
    assert id == d.id

    assert {:existing, %{id: ^id}} = Deployments.start(board, attrs)
    assert [%{deployment_id: ^id}] = Deployments.shipped(card)
    assert length(Deployments.list(board)) == 1
  end
end
