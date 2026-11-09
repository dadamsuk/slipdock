defmodule SlipdockWeb.API.MachineProbeControllerTest do
  @moduledoc """
  A runner's probe over the API (#2580): the owner sends one and reads it,
  a member of the runner's board reads it and sends none; and the runner
  protocol hands the daemon its probe with no card headers, its prompt the
  drift verdict, and takes its finish.
  """
  # Sync: each test resets the rate-limit counts, which are one table for the
  # node (RateLimit.reset/0 clears everybody's).
  use SlipdockWeb.ConnCase, async: false

  import Ecto.Query
  import Slipdock.Fixtures

  alias Slipdock.{Machines, Repo, Runners}
  alias Slipdock.Runners.{Job, MachineRunners}

  @about %{"hostname" => "build-box", "os" => "linux", "arch" => "amd64"}

  setup %{user: user} do
    Slipdock.RateLimit.reset()
    board = board_fixture(%{"name" => "Served", "code" => unique_code()}, owner: user)
    {:ok, key, _} = Machines.create_enrolment_key(user, [board.id])
    {:ok, {machine_key, machine}} = Machines.enrol_with_key(key, @about)

    {:ok, runner} =
      MachineRunners.add_runner(machine, board, %{
        "pool" => "build",
        "config" => %{"directory" => "/srv/src/app"}
      })

    %{board: board, machine: machine, key: machine_key, runner: runner}
  end

  defp path(ctx), do: ~p"/api/machines/#{ctx.machine.id}/runners/#{ctx.runner.id}/probe"

  defp protocol(ctx) do
    build_conn()
    |> put_req_header("authorization", "Bearer " <> ctx.key)
    |> put_req_header("x-runner-id", to_string(ctx.runner.id))
    |> put_req_header("content-type", "text/plain")
  end

  describe "the owner" do
    test "sends a probe (201), again is the same one (200), and reads it", ctx do
      assert %{"probe" => p} = ctx.conn |> post(path(ctx)) |> json_response(201)
      assert p["result"] == "pending"
      assert p["status"] == "queued"
      assert p["runner_id"] == ctx.runner.id

      assert %{"probe" => %{"id" => same}} = ctx.conn |> post(path(ctx)) |> json_response(200)
      assert same == p["id"]

      assert %{"probe" => %{"id" => ^same, "result" => "pending"}} =
               ctx.conn |> get(path(ctx)) |> json_response(200)
    end

    test "reads no probe as null, and a paused runner's is refused", ctx do
      assert %{"probe" => nil} = ctx.conn |> get(path(ctx)) |> json_response(200)

      {:ok, _} = MachineRunners.pause_runner(ctx.runner)

      assert %{"error" => error} = ctx.conn |> post(path(ctx)) |> json_response(422)
      assert error =~ "is paused: resume it, then probe it"
    end

    test "an unknown runner or machine is not found", ctx do
      assert ctx.conn
             |> post(~p"/api/machines/#{ctx.machine.id}/runners/999999/probe")
             |> json_response(404)

      assert ctx.conn |> post(~p"/api/machines/999999/runners/1/probe") |> json_response(404)
    end

    test "the machine shows each runner's latest probe, green or red with its log", ctx do
      {:ok, probe} = Runners.Probe.send_probe(ctx.machine, ctx.runner)

      Repo.update_all(from(j in Job, where: j.id == ^probe.id),
        set: [status: "failed", exit_code: 1, output: "FAIL gh: not signed in\n"]
      )

      assert %{"machine" => %{"runners" => [r]}} =
               ctx.conn |> get(~p"/api/machines/#{ctx.machine.id}") |> json_response(200)

      assert %{"result" => "red", "log" => "FAIL gh: not signed in\n", "exit_code" => 1} =
               r["probe"]
    end
  end

  describe "a member of the runner's board" do
    setup ctx do
      member = user_fixture("member@example.com")
      {:ok, _} = Slipdock.Access.grant(ctx.board, member, "read", ctx.user)
      %{member: conn_as(member)}
    end

    test "reads its probe and can't send one", ctx do
      {:ok, probe} = Runners.Probe.send_probe(ctx.machine, ctx.runner)

      assert %{"probe" => %{"id" => id}} = ctx.member |> get(path(ctx)) |> json_response(200)
      assert id == probe.id

      assert %{"error" => "only the machine's owner changes it" <> _} =
               ctx.member |> post(path(ctx)) |> json_response(403)
    end

    test "doesn't read the probe of a runner on a board they aren't on", ctx do
      other = board_fixture(%{"name" => "Private", "code" => unique_code()}, owner: ctx.user)
      {:ok, machine} = Machines.get_machine(ctx.user, ctx.machine.id)
      machine = Repo.update!(Ecto.Changeset.change(machine, board_ids: [ctx.board.id, other.id]))

      {:ok, hidden} =
        MachineRunners.add_runner(machine, other, %{
          "pool" => "build",
          "name" => "hidden",
          "config" => %{"directory" => "/srv/src/app"}
        })

      assert %{"error" => "no such runner on this machine"} =
               ctx.member
               |> get(~p"/api/machines/#{ctx.machine.id}/runners/#{hidden.id}/probe")
               |> json_response(404)
    end

    test "someone with no board of the machine's doesn't see it" do
      stranger = conn_as(user_fixture("stranger@example.com"))
      assert stranger |> get(~p"/api/machines/1/runners/1/probe") |> json_response(404)
    end
  end

  describe "the runner protocol" do
    test "hands the daemon its probe with no card, and takes its finish", ctx do
      {:ok, probe} = Runners.Probe.send_probe(ctx.machine, ctx.runner)

      conn =
        ctx
        |> protocol()
        |> put_req_header("x-runner-kinds", "claude,verify,merge,probe")
        |> put_req_header("x-runner-cli", "none")
        |> post("/api/runner/claim?wait=0")

      assert conn.status == 200
      assert get_resp_header(conn, "x-job-id") == [to_string(probe.id)]
      assert get_resp_header(conn, "x-job-kind") == ["probe"]
      assert get_resp_header(conn, "x-card-id") == []
      assert get_resp_header(conn, "x-card-url") == []
      assert get_resp_header(conn, "x-board-id") == [to_string(ctx.board.id)]
      assert conn.resp_body =~ "probe of runner #{ctx.runner.name}"
      assert conn.resp_body =~ "\ncli: none\n"

      beat = ctx |> protocol() |> post("/api/runner/jobs/#{probe.id}/heartbeat", "ok   gh\n")
      assert beat.resp_body == "ok\n"

      finish =
        ctx
        |> protocol()
        |> post("/api/runner/jobs/#{probe.id}/finish?exit=0", "probe: green\n")

      assert finish.resp_body == "ok done\n"

      assert %{"probe" => %{"result" => "green", "log" => "probe: green\n"}} =
               ctx.conn |> get(path(ctx)) |> json_response(200)
    end
  end
end
