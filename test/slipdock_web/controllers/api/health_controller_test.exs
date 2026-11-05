defmodule SlipdockWeb.API.HealthControllerTest do
  @moduledoc """
  The health monitor over HTTP (W-2310): incidents listed on the tree's root
  board, a run started, detector settings changed, and every write refused to
  a reader, a read-only token and a stranger.
  """
  use SlipdockWeb.ConnCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Access, Accounts, Repo}
  alias Slipdock.Health.{Incident, Pulse}

  setup %{user: owner} do
    board = board_fixture(%{}, owner: owner)
    # Flagged by the monitor, so the card carries the stuck flag.
    card = card_fixture(Enum.at(board.columns, 1), %{"title" => "Stalled", "flags" => ["stuck"]})
    reader = user_fixture("health-reader@example.com")
    {:ok, _} = Access.grant(board, reader, "read", owner)
    stranger = user_fixture("health-stranger@example.com")

    flagged =
      Repo.insert!(%Incident{
        board_id: board.id,
        card_id: card.id,
        detector: "no_runner",
        fingerprint: "a1",
        summary: "Nobody takes job #3",
        status: "flagged",
        log: [%{"at" => "2026-11-05T09:00:00Z", "what" => "Found: Nobody takes job #3"}]
      })

    Repo.insert!(%Incident{
      board_id: board.id,
      detector: "idle_feed",
      fingerprint: "b2",
      summary: "The feed sat idle",
      status: "fixed",
      attempts: 1
    })

    %{
      board: board,
      owner: owner,
      reader: reader,
      stranger: stranger,
      card: card,
      flagged: flagged
    }
  end

  defp as(user), do: user |> conn_as() |> put_req_header("accept", "application/json")

  defp read_only(user) do
    {token, _} = Accounts.create_api_token(user, "ro", scope: "read")

    build_conn()
    |> put_req_header("accept", "application/json")
    |> put_req_header("authorization", "Bearer " <> token)
  end

  test "GET lists the active and recent incidents, with the card and last run", ctx do
    Pulse.beat("monitor", ~U[2026-11-05 09:00:00Z])

    assert %{"incidents" => [i], "recent" => [r], "last_run" => last, "detectors" => detectors} =
             as(ctx.reader) |> get("/api/boards/#{ctx.board.code}/health") |> json_response(200)

    assert i["id"] == ctx.flagged.id
    assert i["status"] == "flagged"
    assert i["card"] == %{"id" => ctx.card.id, "title" => "Stalled", "board_id" => ctx.board.id}
    assert [%{"what" => "Found: Nobody takes job #3"}] = i["log"]
    assert r["detector"] == "idle_feed" and r["status"] == "fixed"
    assert last =~ "2026-11-05T09:00:00"
    assert is_list(detectors)
  end

  test "POST runs the monitor for a writer, and answers the listing", ctx do
    assert %{"incidents" => [_]} =
             as(ctx.owner)
             |> post("/api/boards/#{ctx.board.code}/health", %{})
             |> json_response(200)
  end

  test "a reader, a read-only token and a stranger can't run it", ctx do
    assert as(ctx.reader)
           |> post("/api/boards/#{ctx.board.code}/health", %{})
           |> json_response(403)

    assert read_only(ctx.owner)
           |> post("/api/boards/#{ctx.board.code}/health", %{})
           |> json_response(403)

    assert as(ctx.stranger) |> get("/api/boards/#{ctx.board.code}/health") |> json_response(404)
  end

  test "PATCH settings needs a known detector, and write access", ctx do
    assert %{"error" => error} =
             as(ctx.owner)
             |> patch("/api/boards/#{ctx.board.code}/health/settings", %{"detector" => "nope"})
             |> json_response(400)

    assert error =~ "unknown detector"

    assert %{"error" => "detector is required" <> _} =
             as(ctx.owner)
             |> patch("/api/boards/#{ctx.board.code}/health/settings", %{})
             |> json_response(400)

    assert as(ctx.reader)
           |> patch("/api/boards/#{ctx.board.code}/health/settings", %{"detector" => "nope"})
           |> json_response(403)
  end
end
