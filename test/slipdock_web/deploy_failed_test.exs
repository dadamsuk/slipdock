defmodule SlipdockWeb.DeployFailedTest do
  @moduledoc """
  A release that failed (#2820): CI's failure job records where it failed
  and its run (`POST /api/deployments/failed`, `Slipdock.Deployments.
  record_failure/2`), finishing the deploy job's own record of the attempt
  when there is one; a card whose latest deploy attempt failed says so in
  every door until a succeeded deploy naming it replaces the line; and a
  failure before anything reached the environment is no deploy to DORA.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.DataCase, only: [errors_on: 1]
  import Slipdock.Fixtures

  alias Slipdock.{Boards, Deployments, Dora, Repo}
  alias Slipdock.Deployments.Deployment

  @sha "aaaaaaa1111111"
  @sha2 "bbbbbbb2222222"
  @run "https://github.com/example/app/actions/runs/42"

  setup %{conn: conn, user: user} do
    board = board_fixture(%{"name" => "Releases"}, owner: user)
    {:ok, board} = Boards.update_board(board, %{"delivery_metrics" => true})
    [_backlog, todo | _] = board.columns
    card = card_fixture(todo, %{"title" => "Feature"})
    json = put_req_header(conn, "accept", "application/json")

    %{"token" => token} =
      json |> post(~p"/api/boards/#{board.code}/deploy-token") |> json_response(200)

    %{conn: conn, json: json, board: board, card: card, token: token}
  end

  defp ci(token) do
    build_conn()
    |> put_req_header("accept", "application/json")
    |> put_req_header("authorization", "Bearer " <> token)
  end

  defp commits(card, sha \\ @sha), do: [%{"sha" => sha, "subject" => "feat: it (##{card.id})"}]

  defp fail!(board, card, attrs) do
    {:ok, d} =
      Deployments.record_failure(
        board,
        Map.merge(
          %{environment: "production", sha: @sha, run_url: @run, commits: commits(card)},
          attrs
        )
      )

    d
  end

  defp succeed!(board, card, sha, at) do
    {:ok, d} =
      Deployments.start(board, %{
        environment: "production",
        sha: sha,
        status: "succeeded",
        started_at: at,
        finished_at: at,
        commits: commits(card, sha)
      })

    d
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

  describe "recording a failure" do
    test "a new failed row, with its stage, run and the cards its commits name", %{
      board: board,
      card: card
    } do
      d = fail!(board, card, %{stage: "build"})
      assert d.status == "failed"
      assert d.stage == "build"
      assert d.run_url == @run
      assert d.finished_at
      assert d.card_ids == [card.id]
    end

    test "the deploy job's own started record is the one finished, not a second row", %{
      board: board,
      card: card
    } do
      {:ok, started} =
        Deployments.start(board, %{
          environment: "production",
          sha: @sha,
          run_url: @run,
          commits: commits(card)
        })

      d = fail!(board, card, %{stage: "health"})
      assert d.id == started.id
      assert d.status == "failed"
      assert d.stage == "health"
      assert d.finished_at
      assert Repo.aggregate(Deployment, :count) == 1
    end

    test "a record the deploy job already finished as failed is told its stage", %{
      board: board,
      card: card
    } do
      # An older CLI sent no run url on start: the attempt is still this one.
      {:ok, started} =
        Deployments.start(board, %{environment: "production", sha: @sha, commits: commits(card)})

      {:ok, finished} = Deployments.finish(board, started.id, "failed")

      d = fail!(board, card, %{stage: "deploy"})
      assert d.id == started.id
      assert d.stage == "deploy"
      assert d.run_url == @run
      assert d.finished_at == finished.finished_at
      assert Repo.aggregate(Deployment, :count) == 1
    end

    test "another run's record, or one with a stage already, gets a row of its own", %{
      board: board,
      card: card
    } do
      {:ok, _} =
        Deployments.start(board, %{
          environment: "production",
          sha: @sha,
          run_url: @run <> "0",
          commits: commits(card)
        })

      first = fail!(board, card, %{stage: "deploy"})
      second = fail!(board, card, %{stage: "build"})
      assert first.run_url == @run
      assert second.id != first.id
      assert Repo.aggregate(Deployment, :count) == 3
    end

    test "no stage, an unknown one, or a run that isn't a web address is refused", %{
      board: board
    } do
      base = %{environment: "production", sha: @sha}
      assert {:error, cs} = Deployments.record_failure(board, base)
      assert hd(errors_on(cs).stage) =~ "is required"

      assert {:error, cs} = Deployments.record_failure(board, Map.put(base, :stage, "lint"))
      assert hd(errors_on(cs).stage) =~ "must be one of build, test, merge, deploy, health"

      assert {:error, cs} =
               Deployments.record_failure(
                 board,
                 Map.merge(base, %{stage: "build", run_url: "javascript:alert(1)"})
               )

      assert "must be an http(s) URL" in errors_on(cs).run_url
      assert Repo.aggregate(Deployment, :count) == 0
    end

    test "nothing is recorded while delivery metrics are off", %{board: board, card: card} do
      {:ok, board} = Boards.update_board(board, %{"delivery_metrics" => false})

      assert Deployments.record_failure(board, %{
               environment: "production",
               sha: @sha,
               stage: "build",
               commits: commits(card)
             }) == {:error, :off}

      assert Repo.aggregate(Deployment, :count) == 0
    end
  end

  describe "POST /api/deployments/failed" do
    test "records it and answers with the stage and run", %{token: token, card: card} do
      body =
        ci(token)
        |> post(~p"/api/deployments/failed", %{
          "environment" => "production",
          "sha" => @sha,
          "stage" => "build",
          "run_url" => @run,
          "commits" => commits(card)
        })
        |> json_response(201)

      d = body["deployment"]
      assert d["status"] == "failed"
      assert d["stage"] == "build"
      assert d["run_url"] == @run
      assert d["cards"] == [card.id]
    end

    test "a bad stage or run url is a 422", %{token: token} do
      body =
        ci(token)
        |> post(~p"/api/deployments/failed", %{"environment" => "production", "sha" => @sha})
        |> json_response(422)

      assert body["details"]["stage"]

      body =
        ci(token)
        |> post(~p"/api/deployments/failed", %{
          "environment" => "production",
          "sha" => @sha,
          "stage" => "build",
          "run_url" => "not a url"
        })
        |> json_response(422)

      assert body["details"]["run_url"]
      assert Repo.aggregate(Deployment, :count) == 0
    end

    test "refused while delivery metrics are off, and without the deploy token", %{
      token: token,
      board: board,
      json: json
    } do
      attrs = %{"environment" => "production", "sha" => @sha, "stage" => "build"}

      # An API token can't record one.
      assert json |> post(~p"/api/deployments/failed", attrs) |> json_response(401)

      {:ok, _} = Boards.update_board(board, %{"delivery_metrics" => false})
      body = ci(token) |> post(~p"/api/deployments/failed", attrs) |> json_response(403)
      assert body["error"] == "delivery_metrics_off"
      assert Repo.aggregate(Deployment, :count) == 0
    end

    test "deploy start keeps the run url it is given", %{token: token} do
      d =
        ci(token)
        |> post(~p"/api/deployments", %{
          "environment" => "production",
          "sha" => @sha,
          "run_url" => @run
        })
        |> json_response(201)
        |> Map.fetch!("deployment")

      assert d["run_url"] == @run
      assert d["stage"] == nil
    end
  end

  describe "the card's line" do
    test "appears when its latest attempt failed, and a later succeeded deploy replaces it", %{
      board: board,
      card: card
    } do
      succeed!(board, card, "ccccccc3333333", ~U[2026-11-01 09:00:00.000000Z])
      assert Deployments.deploy_failed(card) == []

      fail!(board, card, %{
        stage: "build",
        started_at: ~U[2026-11-11 20:41:00.000000Z],
        finished_at: ~U[2026-11-11 20:41:00.000000Z]
      })

      assert [line] = Deployments.deploy_failed(card)
      assert line.stage == "build"
      assert line.run_url == @run

      assert Deployments.deploy_failed_text(line) ==
               "Deploy failed at build · production · #{@run} · 11 Nov 20:41"

      # The succeeded deploy before it still shows it shipped, as it did.
      assert [_] = Deployments.shipped(card)

      succeed!(board, card, @sha2, ~U[2026-11-11 21:30:00.000000Z])
      assert Deployments.deploy_failed(card) == []
    end

    test "a deploy job's started record doesn't hide a failure until it finishes", %{
      board: board,
      card: card
    } do
      fail!(board, card, %{stage: "merge", started_at: ~U[2026-11-11 20:41:00.000000Z]})

      {:ok, started} =
        Deployments.start(board, %{
          environment: "production",
          sha: @sha2,
          commits: commits(card, @sha2)
        })

      assert [%{stage: "merge"}] = Deployments.deploy_failed(card)
      {:ok, _} = Deployments.finish(board, started.id, "succeeded")
      assert Deployments.deploy_failed(card) == []
    end

    test "with no stage or run it still says the attempt failed", %{board: board, card: card} do
      {:ok, d} =
        Deployments.start(board, %{
          environment: "staging",
          sha: @sha,
          status: "failed",
          started_at: ~U[2026-11-11 20:41:00.000000Z],
          commits: commits(card)
        })

      assert [line] = Deployments.deploy_failed(card)
      assert line.deployment_id == d.id
      assert Deployments.deploy_failed_text(line) == "Deploy failed · staging · 11 Nov 20:41"
    end

    test "nothing while the board's delivery metrics are off", %{
      board: board,
      card: card,
      json: json
    } do
      fail!(board, card, %{stage: "build"})
      {:ok, _} = Boards.update_board(board, %{"delivery_metrics" => false})
      assert Deployments.deploy_failed(card) == []

      body = json |> get(~p"/api/cards/#{card.id}") |> json_response(200)
      refute Map.has_key?(body["card"], "deploy_failed")
    end

    test "the card's API JSON, MCP get_card and the card panel carry it", %{
      conn: conn,
      json: json,
      board: board,
      card: card
    } do
      d = fail!(board, card, %{stage: "test", started_at: ~U[2026-11-11 20:41:00.000000Z]})

      body = json |> get(~p"/api/cards/#{card.id}") |> json_response(200)

      assert [%{"stage" => "test", "run_url" => @run, "text" => text} = line] =
               body["card"]["deploy_failed"]

      assert line["deployment_id"] == d.id
      assert text =~ "Deploy failed at test · production · #{@run}"

      assert [%{"text" => ^text}] = mcp_card(conn, card)["deploy_failed"]

      {:ok, view, _} = live(conn, ~p"/boards/#{board}/cards/#{card.id}")
      assert has_element?(view, "#card-deploy-failed", "Deploy failed at test")
      assert has_element?(view, ~s(#card-deploy-failed a[href="#{@run}"]), "run")

      succeed!(board, card, @sha2, DateTime.utc_now())
      body = json |> get(~p"/api/cards/#{card.id}") |> json_response(200)
      refute Map.has_key?(body["card"], "deploy_failed")

      {:ok, view, _} = live(conn, ~p"/boards/#{board}/cards/#{card.id}")
      refute has_element?(view, "#card-deploy-failed")
    end
  end

  describe "DORA" do
    test "a build, test or merge failure is no deploy; a deploy or health failure is", %{
      board: board,
      card: card
    } do
      now = DateTime.utc_now()
      at = DateTime.add(now, -3600)
      succeed!(board, card, "ccccccc3333333", at)

      for stage <- ~w(build test merge) do
        fail!(board, card, %{stage: stage, run_url: @run <> stage, started_at: at})
      end

      {:ok, r} = Dora.for_board(board, now: now)
      assert r.change_failure_rate.rate == 0.0

      fail!(board, card, %{stage: "health", run_url: @run <> "h", started_at: at})
      {:ok, r} = Dora.for_board(board, now: now)
      assert r.change_failure_rate.rate == 0.5
      assert r.deployment_frequency.deploys == 1
    end

    test "a backfill of a sha whose build failed is still recorded", %{board: board, card: card} do
      fail!(board, card, %{stage: "build"})

      assert {:ok, %Deployment{status: "succeeded"}} =
               Deployments.start(board, %{
                 environment: "production",
                 sha: @sha,
                 source: "backfill",
                 status: "succeeded"
               })
    end
  end
end
