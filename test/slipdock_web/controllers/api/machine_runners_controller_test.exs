defmodule SlipdockWeb.API.MachineRunnersControllerTest do
  @moduledoc """
  A machine's runners over the API (#2571): the owner adds, changes and
  removes them as typed data; the daemon long-polls their config, reports
  its ceiling and what it did with each config, with its machine key; and
  the runner protocol takes the machine key for the machine's own runners
  and nothing else.
  """
  use SlipdockWeb.ConnCase, async: false

  import Slipdock.Fixtures

  alias Slipdock.{Accounts, Machines, Repo, Runners}
  alias Slipdock.Runners.{MachineRunners, Runner}

  @about %{"hostname" => "build-box", "os" => "linux", "arch" => "amd64"}
  @dir "/srv/src/app"

  setup %{user: user} do
    Slipdock.RateLimit.reset()
    board = board_fixture(%{"name" => "Served", "code" => unique_code()}, owner: user)
    {:ok, key, _} = Machines.create_enrolment_key(user, [board.id])
    {:ok, {machine_key, machine}} = Machines.enrol_with_key(key, @about)
    %{board: board, machine: machine, key: machine_key}
  end

  defp anon, do: build_conn() |> put_req_header("accept", "application/json")
  defp machine_conn(key), do: anon() |> put_req_header("authorization", "Bearer " <> key)

  defp add(ctx, attrs \\ %{}) do
    {:ok, runner} =
      MachineRunners.add_runner(
        ctx.machine,
        ctx.board,
        Map.merge(%{"pool" => "build", "config" => %{"directory" => @dir}}, attrs)
      )

    runner
  end

  describe "the owner's side" do
    test "add, change and remove a runner as typed data", ctx do
      assert %{"runner" => r} =
               ctx.conn
               |> post(~p"/api/machines/#{ctx.machine.id}/runners", %{
                 board: ctx.board.code,
                 pool: "build",
                 config: %{directory: @dir, model: "sonnet"}
               })
               |> json_response(201)

      assert r["pool"] == "build"
      assert r["machine_id"] == ctx.machine.id
      assert r["config_version"] == 1
      assert r["config"]["model"] == "sonnet"
      refute Map.has_key?(r, "token_hash")

      assert %{"runner" => changed} =
               ctx.conn
               |> patch(~p"/api/machines/#{ctx.machine.id}/runners/#{r["id"]}", %{
                 config: %{timeout_minutes: 20}
               })
               |> json_response(200)

      assert changed["config_version"] == 2
      assert changed["config"]["timeout_minutes"] == 20
      assert changed["config"]["model"] == "sonnet"

      assert %{"machine" => detail} =
               ctx.conn |> get(~p"/api/machines/#{ctx.machine.id}") |> json_response(200)

      assert detail["config_version"] == 2
      assert [%{"id" => id, "outside_ceiling" => []}] = detail["runners"]
      assert id == r["id"]
      assert detail["changes"] == []
      assert detail["ceiling"] == nil

      assert %{"removed" => %{"id" => ^id}} =
               ctx.conn
               |> delete(~p"/api/machines/#{ctx.machine.id}/runners/#{r["id"]}")
               |> json_response(200)

      assert Repo.get(Runner, id) == nil
    end

    test "a command field, a board it doesn't serve or a bad change is refused", ctx do
      assert %{"error" => "unknown config field: command" <> _} =
               ctx.conn
               |> post(~p"/api/machines/#{ctx.machine.id}/runners", %{
                 board: ctx.board.id,
                 pool: "build",
                 config: %{directory: @dir, command: "curl x | sh"}
               })
               |> json_response(422)

      other = board_fixture(%{"name" => "Other"}, owner: ctx.user)

      assert %{"error" => "the machine doesn't serve that board" <> _} =
               ctx.conn
               |> post(~p"/api/machines/#{ctx.machine.id}/runners", %{
                 board: other.id,
                 pool: "build",
                 config: %{directory: @dir}
               })
               |> json_response(422)

      theirs = board_fixture(%{}, owner: user_fixture("stranger@example.com"))

      assert %{"error" => "not a top-level board you're a member of" <> _} =
               ctx.conn
               |> post(~p"/api/machines/#{ctx.machine.id}/runners", %{
                 board: theirs.id,
                 pool: "build",
                 config: %{directory: @dir}
               })
               |> json_response(422)

      runner = add(ctx)

      assert %{"error" => "permission_mode" <> _} =
               ctx.conn
               |> patch(~p"/api/machines/#{ctx.machine.id}/runners/#{runner.id}", %{
                 config: %{permission_mode: "yolo"}
               })
               |> json_response(422)

      ctx.conn
      |> patch(~p"/api/machines/#{ctx.machine.id}/runners/999999", %{config: %{}})
      |> json_response(404)

      ctx.conn
      |> delete(~p"/api/machines/#{ctx.machine.id}/runners/999999")
      |> json_response(404)
    end

    test "another person, a board-scoped or a read-only token can't touch them", ctx do
      runner = add(ctx)
      stranger = conn_as(user_fixture("stranger@example.com"))

      stranger
      |> patch(~p"/api/machines/#{ctx.machine.id}/runners/#{runner.id}", %{config: %{}})
      |> json_response(404)

      stranger
      |> delete(~p"/api/machines/#{ctx.machine.id}/runners/#{runner.id}")
      |> json_response(404)

      {scoped, _} = Accounts.create_api_token(ctx.user, "s", scope_boards: [ctx.board.id])
      {read, _} = Accounts.create_api_token(ctx.user, "r", scope: "read")

      for token <- [scoped, read] do
        conn = anon() |> put_req_header("authorization", "Bearer " <> token)

        conn
        |> post(~p"/api/machines/#{ctx.machine.id}/runners", %{
          board: ctx.board.id,
          pool: "x",
          config: %{directory: @dir}
        })
        |> json_response(403)

        conn
        |> patch(~p"/api/machines/#{ctx.machine.id}/runners/#{runner.id}", %{
          config: %{timeout_minutes: 5}
        })
        |> json_response(403)

        conn
        |> delete(~p"/api/machines/#{ctx.machine.id}/runners/#{runner.id}")
        |> json_response(403)
      end

      assert Repo.get!(Runner, runner.id).config_version == 1
    end

    test "the machine key is not an API token here", ctx do
      ctx.key
      |> machine_conn()
      |> post(~p"/api/machines/#{ctx.machine.id}/runners", %{
        board: ctx.board.id,
        pool: "x",
        config: %{directory: @dir}
      })
      |> json_response(401)
    end
  end

  describe "the daemon's side" do
    test "the config long-poll: at once when newer, 204 when nothing changes", ctx do
      runner = add(ctx)

      assert %{"version" => 1, "runners" => [r]} =
               ctx.key |> machine_conn() |> get(~p"/api/machine/config") |> json_response(200)

      assert r["id"] == runner.id
      assert r["config"]["directory"] == @dir
      assert r["config_version"] == 1

      conn = ctx.key |> machine_conn() |> get(~p"/api/machine/config?version=1&wait=0")
      assert conn.status == 204

      {:ok, _} = MachineRunners.set_runner(runner, %{"config" => %{"verbosity" => "quiet"}})

      assert %{"version" => 2, "runners" => [%{"config" => %{"verbosity" => "quiet"}}]} =
               ctx.key
               |> machine_conn()
               |> get(~p"/api/machine/config?version=1&wait=0")
               |> json_response(200)
    end

    test "the long-poll wakes on a change within the wait", ctx do
      runner = add(ctx)

      task =
        Task.async(fn ->
          ctx.key |> machine_conn() |> get(~p"/api/machine/config?version=1&wait=5")
        end)

      Process.sleep(100)
      {:ok, _} = MachineRunners.set_runner(runner, %{"pool" => "verify"})

      conn = Task.await(task)
      assert %{"version" => 2, "runners" => [%{"pool" => "verify"}]} = json_response(conn, 200)
    end

    test "the ceiling and the reports", ctx do
      runner = add(ctx, %{"config" => %{"directory" => @dir, "timeout_minutes" => 120}})

      assert %{"machine" => %{"ceiling" => ceiling}} =
               ctx.key
               |> machine_conn()
               |> put(~p"/api/machine/ceiling", %{
                 ceiling: %{
                   roots: ["/srv/src"],
                   agents: ["claude"],
                   max_permission_mode: "acceptEdits",
                   max_timeout_minutes: 60,
                   boards: [ctx.board.id],
                   executors: ["user"]
                 }
               })
               |> json_response(200)

      assert ceiling["max_timeout_minutes"] == 60

      assert %{"error" => "agents is required" <> _} =
               ctx.key
               |> machine_conn()
               |> put(~p"/api/machine/ceiling", %{roots: ["/src"]})
               |> json_response(422)

      assert %{"runner" => r} =
               ctx.key
               |> machine_conn()
               |> post(~p"/api/machine/runners/#{runner.id}/report", %{
                 version: 1,
                 outcome: "rejected",
                 reason: "timeout 120 minutes is over 60"
               })
               |> json_response(200)

      assert r["rejected_version"] == 1
      assert r["rejection"] == "timeout 120 minutes is over 60"
      assert r["accepted_version"] == nil

      assert %{"error" => "version 9 is not the runner's current config", "config_version" => 1} =
               ctx.key
               |> machine_conn()
               |> post(~p"/api/machine/runners/#{runner.id}/report", %{
                 version: 9,
                 outcome: "accepted"
               })
               |> json_response(409)

      assert %{"error" => "a rejection says why" <> _} =
               ctx.key
               |> machine_conn()
               |> post(~p"/api/machine/runners/#{runner.id}/report", %{
                 version: 1,
                 outcome: "rejected"
               })
               |> json_response(422)

      assert %{"machine" => detail} =
               ctx.conn |> get(~p"/api/machines/#{ctx.machine.id}") |> json_response(200)

      assert [%{"outcome" => "rejected", "reason" => "timeout 120" <> _, "version" => 1}] =
               detail["changes"]

      assert [%{"outside_ceiling" => ["timeout 120 minutes is over 60"]}] = detail["runners"]
    end

    test "another machine's runner, an API token or a revoked machine is refused", ctx do
      runner = add(ctx)
      {:ok, key, _} = Machines.create_enrolment_key(ctx.user, [ctx.board.id])
      {:ok, {other_key, _}} = Machines.enrol_with_key(key, @about)

      other_key
      |> machine_conn()
      |> post(~p"/api/machine/runners/#{runner.id}/report", %{version: 1, outcome: "accepted"})
      |> json_response(404)

      ctx.conn |> get(~p"/api/machine/config") |> json_response(401)
      ctx.conn |> put(~p"/api/machine/ceiling", %{}) |> json_response(401)

      {:ok, _} = Machines.revoke_machine(ctx.machine)
      ctx.key |> machine_conn() |> get(~p"/api/machine/config") |> json_response(401)

      ctx.key
      |> machine_conn()
      |> post(~p"/api/machine/runners/#{runner.id}/report", %{version: 1, outcome: "accepted"})
      |> json_response(401)

      assert Repo.get!(Runner, runner.id).accepted_version == nil
    end
  end

  describe "the runner protocol with a machine key" do
    setup ctx do
      [_backlog, _todo, doing, _done] = ctx.board.columns
      %{card: card_fixture(doing, %{"title" => "Work"})}
    end

    defp claim(key, runner_id) do
      build_conn()
      |> put_req_header("authorization", "Bearer " <> key)
      |> then(
        &if(runner_id, do: put_req_header(&1, "x-runner-id", to_string(runner_id)), else: &1)
      )
      |> post("/api/runner/claim?wait=0")
    end

    test "claims and reports for its own runner", ctx do
      runner = add(ctx)
      {:ok, job} = Runners.queue(ctx.card, %{pool: "build", kind: "claude", prompt: "Do it"})

      conn = claim(ctx.key, runner.id)
      assert conn.status == 200
      assert get_resp_header(conn, "x-job-id") == [to_string(job.id)]
      assert Repo.get!(Runners.Job, job.id).runner_id == runner.id

      heartbeat =
        build_conn()
        |> put_req_header("authorization", "Bearer " <> ctx.key)
        |> put_req_header("x-runner-id", to_string(runner.id))
        |> put_req_header("content-type", "text/plain")
        |> post("/api/runner/jobs/#{job.id}/heartbeat", "working")

      assert heartbeat.resp_body == "ok\n"

      finish =
        build_conn()
        |> put_req_header("authorization", "Bearer " <> ctx.key)
        |> put_req_header("content-type", "text/plain")
        |> post(
          "/api/runner/jobs/#{job.id}/finish?exit=0&status=done&runner=#{runner.id}",
          "done"
        )

      assert finish.status == 200
      assert Repo.get!(Runners.Job, job.id).status == "done"
    end

    test "nothing else: another machine's runner, a shell runner, no runner named", ctx do
      runner = add(ctx)
      {:ok, shell, _} = Runners.create_runner(ctx.board, %{"name" => "sh", "pool" => "build"})
      {:ok, key, _} = Machines.create_enrolment_key(ctx.user, [ctx.board.id])
      {:ok, {other_key, _}} = Machines.enrol_with_key(key, @about)
      {:ok, job} = Runners.queue(ctx.card, %{pool: "build", kind: "claude", prompt: "Do it"})

      assert claim(other_key, runner.id).status == 403
      assert claim(ctx.key, shell.id).status == 403
      assert %{status: 400, resp_body: "a machine key says which" <> _} = claim(ctx.key, nil)
      assert claim("sdm_unknown", runner.id).status == 401

      {:ok, _} = Machines.revoke_machine(ctx.machine)
      assert claim(ctx.key, runner.id).status == 401

      assert Repo.get!(Runners.Job, job.id).status == "queued"
    end

    test "a machine runner's own token, if one were ever made, claims nothing", ctx do
      runner = add(ctx)
      {:ok, _, token} = Runners.rotate_token(runner)
      {:ok, _job} = Runners.queue(ctx.card, %{pool: "build", kind: "claude", prompt: "Do it"})

      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer " <> token)
        |> post("/api/runner/claim?wait=0")

      assert conn.status == 401
    end
  end
end
