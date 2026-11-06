defmodule Slipdock.Runners.ScriptVersionTest do
  @moduledoc """
  Ship by PR 5 (#1658), the server's side: a runner says which script it
  runs, the server keeps it and answers with the one it hands out, and the
  runner's JSON says whether it is out of date and which kinds its board
  needs that it lacks.
  """
  use SlipdockWeb.ConnCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Boards, Repo, Runners}
  alias Slipdock.Runners.Runner
  alias SlipdockWeb.RunnerInstallController

  @old String.duplicate("a", 64)

  setup do
    board = board_fixture(%{"name" => "Versions", "code" => unique_code()})
    {:ok, runner, token} = Runners.create_runner(board, %{"name" => "r", "pool" => "dev"})
    %{board: board, runner: runner, token: token}
  end

  test "report_version keeps a well-formed version only", ctx do
    runner = Runners.report_version(ctx.runner, "SH #{String.upcase(@old)}")
    assert runner.version == "sh #{@old}"
    assert Repo.get!(Runner, runner.id).version == "sh #{@old}"

    assert Runners.report_version(runner, "sh short").version == "sh #{@old}"
    assert Runners.report_version(runner, "bash #{@old}").version == "sh #{@old}"
    assert Runners.report_version(runner, nil).version == "sh #{@old}"
  end

  test "script_state: current, out of date, or unknown" do
    latest = RunnerInstallController.latest()
    assert byte_size(latest["sh"]) == 64 and byte_size(latest["ps1"]) == 64

    assert Runners.script_state(%Runner{version: "sh " <> latest["sh"]}, latest) == :current
    assert Runners.script_state(%Runner{version: "ps1 " <> latest["ps1"]}, latest) == :current
    assert Runners.script_state(%Runner{version: "sh " <> @old}, latest) == :out_of_date
    assert Runners.script_state(%Runner{version: nil}, latest) == :unknown
  end

  test "the published sums are what a runner reports" do
    sums = RunnerInstallController.files()["SHA256SUMS"]
    assert sums =~ RunnerInstallController.latest()["sh"] <> "  slipdock-runner\n"
    assert sums =~ RunnerInstallController.latest()["ps1"] <> "  slipdock-runner.ps1\n"
  end

  test "missing_kinds: merge, on a pull_request board, for a runner that doesn't take it", ctx do
    assert Runners.missing_kinds(ctx.runner) == []

    {:ok, _} =
      Boards.update_board(ctx.board, %{"verify_work" => true, "ship_via" => "pull_request"})

    assert Runners.missing_kinds(ctx.runner) == ["merge"]
    assert Runners.missing_kinds(Runners.report_kinds(ctx.runner, "claude,merge")) == []
  end

  test "a claim stores the version and answers with the latest; the JSON says", ctx do
    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer " <> ctx.token)
      |> put_req_header("x-runner-version", "sh " <> @old)
      |> post("/api/runner/claim?wait=0")

    assert conn.status == 204
    assert get_resp_header(conn, "x-runner-latest") == [RunnerInstallController.latest()["sh"]]

    json = SlipdockWeb.API.JSON.runner(Repo.get!(Runner, ctx.runner.id))
    assert json.version == "sh " <> @old
    assert json.script == "out_of_date"
    assert json.missing_kinds == []
  end

  test "a runner that says nothing gets no latest header, and reads as unknown", ctx do
    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer " <> ctx.token)
      |> post("/api/runner/claim?wait=0")

    assert get_resp_header(conn, "x-runner-latest") == []
    assert SlipdockWeb.API.JSON.runner(Repo.get!(Runner, ctx.runner.id)).script == "unknown"
  end

  describe "a job's finish says the latest too (#1925)" do
    defp claim_job(ctx, version_header) do
      card = card_fixture(hd(ctx.board.columns), %{"title" => "Go"})
      {:ok, _} = Runners.queue(card, %{pool: "dev", kind: "echo", prompt: "go"})

      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer " <> ctx.token)
        |> put_req_header("x-runner-kinds", "echo")

      conn =
        if version_header,
          do: put_req_header(conn, "x-runner-version", version_header),
          else: conn

      conn = post(conn, "/api/runner/claim?wait=0")
      assert conn.status == 200
      conn |> get_resp_header("x-job-id") |> hd()
    end

    defp finish_job(ctx, id) do
      build_conn()
      |> put_req_header("authorization", "Bearer " <> ctx.token)
      |> put_req_header("content-type", "text/plain")
      |> post("/api/runner/jobs/#{id}/finish?exit=0", "done")
    end

    test "a claim that hands out a job, and that job's finish, both carry X-Runner-Latest", ctx do
      id = claim_job(ctx, "sh " <> @old)
      conn = finish_job(ctx, id)

      assert conn.status == 200
      assert get_resp_header(conn, "x-runner-latest") == [RunnerInstallController.latest()["sh"]]
    end

    test "a ps1 runner's finish names the ps1 script", ctx do
      id = claim_job(ctx, "ps1 " <> @old)
      conn = finish_job(ctx, id)

      assert get_resp_header(conn, "x-runner-latest") == [RunnerInstallController.latest()["ps1"]]
    end

    test "a runner that never said its version gets no latest on finish", ctx do
      id = claim_job(ctx, nil)
      conn = finish_job(ctx, id)

      assert conn.status == 200
      assert get_resp_header(conn, "x-runner-latest") == []
    end

    test "a finish for a job that isn't the runner's answers 404 with no latest", ctx do
      _ = claim_job(ctx, "sh " <> @old)
      conn = finish_job(ctx, 999_999_999)

      assert conn.status == 404
      assert get_resp_header(conn, "x-runner-latest") == []
    end
  end
end
