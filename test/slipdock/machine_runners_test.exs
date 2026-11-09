defmodule Slipdock.MachineRunnersTest do
  @moduledoc """
  A runner belongs to a machine and is configured as typed data (#2571):
  adding, changing and removing a machine's runners, each change bumping a
  version the daemon's long-poll wakes on; the daemon's reports (accepted,
  or rejected with the reason) and its ceiling; the machine key claiming for
  its own runners and nothing else; and the verify job's "not the builder"
  check telling two runners of one machine apart.
  """
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Actor, Boards, Machines, Repo, Runners}
  alias Slipdock.Machines.Machine
  alias Slipdock.Runners.{ConfigReport, MachineRunners, Runner}

  @about %{"hostname" => "build-box", "os" => "linux", "arch" => "amd64"}
  @dir "/srv/src/app"
  @ceiling %{
    "roots" => ["/srv/src"],
    "agents" => ["claude"],
    "max_permission_mode" => "acceptEdits",
    "max_timeout_minutes" => 60,
    "boards" => [],
    "executors" => ["user"]
  }

  setup do
    user = user_fixture()
    board = board_fixture(%{"name" => "Served", "code" => unique_code()}, owner: user)
    {:ok, key, _} = Machines.create_enrolment_key(user, [board.id])
    {:ok, {machine_key, machine}} = Machines.enrol_with_key(key, @about)
    %{user: user, board: board, machine: machine, key: machine_key}
  end

  defp add(ctx, attrs \\ %{}) do
    {:ok, runner} =
      MachineRunners.add_runner(
        ctx.machine,
        ctx.board,
        Map.merge(%{"pool" => "build", "config" => %{"directory" => @dir}}, attrs)
      )

    runner
  end

  defp version(machine), do: Repo.get!(Machine, machine.id).config_version

  describe "adding, changing and removing" do
    test "a runner belongs to its machine with a typed config at version 1", ctx do
      runner = add(ctx)

      assert runner.machine_id == ctx.machine.id
      assert runner.board_id == ctx.board.id
      assert runner.pool == "build"
      assert runner.name == "build-box build"
      assert runner.config_version == 1
      assert runner.config["directory"] == @dir
      assert runner.config["agent"] == "claude"
      assert Runner.machine?(runner)
      refute Runner.machine?(%Runner{})
      assert version(ctx.machine) == 1
      assert [%{id: id}] = MachineRunners.list_runners(ctx.machine)
      assert id == runner.id
      assert {:ok, ^runner} = MachineRunners.get_runner(ctx.machine, "build-box build")
    end

    test "a command, a board it doesn't serve or a revoked machine is refused", ctx do
      assert {:error, :invalid, "unknown config field: command" <> _} =
               MachineRunners.add_runner(ctx.machine, ctx.board, %{
                 "pool" => "build",
                 "config" => %{"directory" => @dir, "command" => "sh -c x"}
               })

      other = board_fixture(%{"name" => "Other"}, owner: ctx.user)

      assert {:error, :invalid, "the machine doesn't serve that board" <> _} =
               MachineRunners.add_runner(ctx.machine, other, %{
                 "pool" => "build",
                 "config" => %{"directory" => @dir}
               })

      assert {:error, :invalid, "pool must be lower case" <> _} =
               MachineRunners.add_runner(ctx.machine, ctx.board, %{
                 "pool" => "Bad Pool!",
                 "config" => %{"directory" => @dir}
               })

      {:ok, revoked} = Machines.revoke_machine(ctx.machine)

      assert {:error, :invalid, "the machine is revoked"} =
               MachineRunners.add_runner(revoked, ctx.board, %{
                 "pool" => "build",
                 "config" => %{"directory" => @dir}
               })

      assert MachineRunners.list_runners(ctx.machine) == []
      assert version(ctx.machine) == 0
    end

    test "a change bumps the runner's version and the machine's; no change leaves both", ctx do
      runner = add(ctx)

      assert {:ok, changed} =
               MachineRunners.set_runner(runner, %{
                 "pool" => "verify",
                 "config" => %{"timeout_minutes" => 30}
               })

      assert changed.pool == "verify"
      assert changed.config["timeout_minutes"] == 30
      assert changed.config["directory"] == @dir
      assert changed.config_version == 2
      assert version(ctx.machine) == 2

      assert {:ok, same} =
               MachineRunners.set_runner(changed, %{"config" => %{"timeout_minutes" => 30}})

      assert same.config_version == 2
      assert version(ctx.machine) == 2

      assert {:error, :invalid, "unknown config field: command" <> _} =
               MachineRunners.set_runner(changed, %{"config" => %{"command" => "x"}})

      assert {:error, :invalid, "timeout_minutes" <> _} =
               MachineRunners.set_runner(changed, %{"config" => %{"timeout_minutes" => 0}})

      assert Repo.get!(Runner, runner.id).config_version == 2
    end

    test "a shell runner isn't set this way", ctx do
      {:ok, shell, _token} =
        Runners.create_runner(ctx.board, %{"name" => "sh", "pool" => "build"})

      assert {:error, :invalid, "not a machine's runner" <> _} =
               MachineRunners.set_runner(shell, %{})
    end

    test "removing one bumps the machine's version and drops it from the config", ctx do
      runner = add(ctx)
      assert {:ok, _} = MachineRunners.remove_runner(runner)
      assert version(ctx.machine) == 2
      assert %{version: 2, runners: []} = MachineRunners.config_for(ctx.machine)
      assert {:error, :not_found, "runner"} = MachineRunners.get_runner(ctx.machine, runner.id)
    end

    test "a machine's runners are only its own", ctx do
      runner = add(ctx)
      {:ok, key, _} = Machines.create_enrolment_key(ctx.user, [ctx.board.id])
      {:ok, {_, other}} = Machines.enrol_with_key(key, @about)

      assert MachineRunners.machine_runner(ctx.machine, runner.id).id == runner.id
      assert MachineRunners.machine_runner(other, runner.id) == nil
      assert MachineRunners.machine_runner(ctx.machine, "x") == nil
      assert MachineRunners.machine_runner(ctx.machine, nil) == nil
      assert {:error, :not_found, _} = MachineRunners.get_runner(other, runner.id)
    end
  end

  describe "the config long-poll" do
    test "answers at once when the version is newer, with each runner's config", ctx do
      runner = add(ctx)

      assert %{version: 1, runners: [r]} = MachineRunners.wait_for_config(ctx.machine, 0, 0)
      assert r.id == runner.id
      assert r.pool == "build"
      assert r.config_version == 1
      assert r.config["directory"] == @dir
      refute Map.has_key?(r, :token_hash)
    end

    test "nothing new by the deadline is nil", ctx do
      add(ctx)
      assert MachineRunners.wait_for_config(ctx.machine, 1, 50) == nil
    end

    test "a change while it waits returns it with the new version", ctx do
      runner = add(ctx)
      parent = self()

      task =
        Task.async(fn ->
          send(parent, :waiting)
          MachineRunners.wait_for_config(ctx.machine, 1, 5_000)
        end)

      assert_receive :waiting
      await_subscribed(MachineRunners.topic(ctx.machine), task.pid)
      started = System.monotonic_time(:millisecond)
      {:ok, _} = MachineRunners.set_runner(runner, %{"config" => %{"model" => "sonnet"}})

      assert %{version: 2, runners: [r]} = Task.await(task)
      assert r.config["model"] == "sonnet"
      assert r.config_version == 2
      assert System.monotonic_time(:millisecond) - started < 2_000
    end

    test "another machine's change doesn't wake it", ctx do
      add(ctx)
      {:ok, key, _} = Machines.create_enrolment_key(ctx.user, [ctx.board.id])
      {:ok, {_, other}} = Machines.enrol_with_key(key, @about)

      task = Task.async(fn -> MachineRunners.wait_for_config(ctx.machine, 1, 300) end)
      await_subscribed(MachineRunners.topic(ctx.machine), task.pid)

      {:ok, _} =
        MachineRunners.add_runner(other, ctx.board, %{
          "pool" => "x",
          "config" => %{"directory" => @dir}
        })

      assert Task.await(task) == nil
    end
  end

  describe "reports and the ceiling" do
    test "accepted: the runner runs that version and config, and the log says so", ctx do
      runner = add(ctx)

      assert {:ok, runner} =
               MachineRunners.report(ctx.machine, runner, %{
                 "version" => 1,
                 "outcome" => "accepted"
               })

      assert runner.accepted_version == 1
      assert runner.accepted_config == runner.config

      assert [%ConfigReport{outcome: "accepted", version: 1, reason: nil}] =
               MachineRunners.reports(ctx.machine)
    end

    test "rejected: stored with the reason, and the last accepted config kept", ctx do
      runner = add(ctx)

      {:ok, runner} =
        MachineRunners.report(ctx.machine, runner, %{version: 1, outcome: "accepted"})

      {:ok, runner} =
        MachineRunners.set_runner(runner, %{"config" => %{"timeout_minutes" => 600}})

      assert {:ok, runner} =
               MachineRunners.report(ctx.machine, runner, %{
                 "version" => "2",
                 "outcome" => "rejected",
                 "reason" => "  timeout 600 minutes is over 60\u0007 "
               })

      runner = Repo.get!(Runner, runner.id)
      assert runner.rejected_version == 2
      assert runner.rejection == "timeout 600 minutes is over 60"
      assert runner.rejected_at
      assert runner.accepted_version == 1
      assert runner.accepted_config["timeout_minutes"] == 60

      assert [%{outcome: "rejected", reason: "timeout 600" <> _}, %{outcome: "accepted"}] =
               MachineRunners.reports(ctx.machine)

      # Fixed and accepted: the rejection clears.
      {:ok, runner} = MachineRunners.set_runner(runner, %{"config" => %{"timeout_minutes" => 45}})

      {:ok, runner} =
        MachineRunners.report(ctx.machine, runner, %{version: 3, outcome: "accepted"})

      assert runner.accepted_version == 3
      assert runner.rejection == nil
      assert runner.rejected_version == nil
    end

    test "a rejection needs a reason; a stale or missing version is refused", ctx do
      runner = add(ctx)

      assert {:error, :invalid, "a rejection says why" <> _} =
               MachineRunners.report(ctx.machine, runner, %{version: 1, outcome: "rejected"})

      assert {:error, :invalid, "outcome must be" <> _} =
               MachineRunners.report(ctx.machine, runner, %{version: 1, outcome: "maybe"})

      assert {:error, :stale, 1} =
               MachineRunners.report(ctx.machine, runner, %{version: 7, outcome: "accepted"})

      assert {:error, :invalid, "version is required" <> _} =
               MachineRunners.report(ctx.machine, runner, %{outcome: "accepted"})

      assert MachineRunners.reports(ctx.machine) == []
    end

    test "a machine can't report on another machine's runner", ctx do
      runner = add(ctx)
      {:ok, key, _} = Machines.create_enrolment_key(ctx.user, [ctx.board.id])
      {:ok, {_, other}} = Machines.enrol_with_key(key, @about)

      assert {:error, :not_found} =
               MachineRunners.report(other, runner, %{version: 1, outcome: "accepted"})
    end

    test "the ceiling is recorded as reported, and says what falls outside it", ctx do
      runner =
        add(ctx, %{"config" => %{"directory" => @dir, "permission_mode" => "bypassPermissions"}})

      assert MachineRunners.outside_ceiling(ctx.machine, runner) == :ok

      assert {:ok, machine} =
               MachineRunners.record_ceiling(ctx.machine, %{@ceiling | "boards" => [ctx.board.id]})

      assert machine.ceiling["roots"] == ["/srv/src"]
      assert machine.ceiling_at
      assert Repo.get!(Machine, machine.id).ceiling["max_permission_mode"] == "acceptEdits"

      assert {:error, ["permission mode bypassPermissions is above acceptEdits"]} =
               MachineRunners.outside_ceiling(machine, runner)

      assert {:error, :invalid, "roots is required" <> _} =
               MachineRunners.record_ceiling(machine, Map.delete(@ceiling, "roots"))

      assert Repo.get!(Machine, machine.id).ceiling["roots"] == ["/srv/src"]
    end
  end

  describe "the machine key" do
    test "claims for its own runners and nothing else", ctx do
      runner = add(ctx)
      {:ok, key, _} = Machines.create_enrolment_key(ctx.user, [ctx.board.id])
      {:ok, {other_key, _other}} = Machines.enrol_with_key(key, @about)

      {:ok, shell, shell_token} =
        Runners.create_runner(ctx.board, %{"name" => "sh", "pool" => "build"})

      assert {:ok, %Runner{id: id, last_seen_at: %DateTime{}}} =
               Runners.authenticate_machine(ctx.key, to_string(runner.id))

      assert id == runner.id
      assert {:error, :not_this_machine} = Runners.authenticate_machine(other_key, runner.id)
      assert {:error, :not_this_machine} = Runners.authenticate_machine(ctx.key, shell.id)
      assert {:error, :no_runner} = Runners.authenticate_machine(ctx.key, nil)
      assert {:error, :no_runner} = Runners.authenticate_machine(ctx.key, "")
      assert {:error, :unauthorized} = Runners.authenticate_machine(shell_token, shell.id)
      assert {:error, :unauthorized} = Runners.authenticate_machine("sdm_nope", runner.id)

      {:ok, _} = Machines.revoke_machine(ctx.machine)
      assert {:error, :unauthorized} = Runners.authenticate_machine(ctx.key, runner.id)
    end

    test "a machine runner is never reached by a runner token", ctx do
      runner = add(ctx)
      {:ok, rotated, token} = Runners.rotate_token(runner)
      assert rotated.machine_id == ctx.machine.id
      assert Runners.authenticate(token) == nil

      {:ok, _shell, shell_token} =
        Runners.create_runner(ctx.board, %{"name" => "sh", "pool" => "build"})

      assert %Runner{name: "sh"} = Runners.authenticate(shell_token)
    end
  end

  describe "two runners of one machine" do
    setup ctx do
      {:ok, board} =
        Boards.update_board(ctx.board, %{"verify_work" => true, "verify_pool" => "checkers"})

      [_backlog, _todo, doing, _done] = board.columns
      %{board: board, card: card_fixture(doing, %{"title" => "Work"})}
    end

    test "the verify job goes to the other runner, never the builder", ctx do
      builder = add(ctx, %{"pool" => "checkers", "name" => "builder"})
      verifier = add(ctx, %{"pool" => "checkers", "name" => "verifier"})
      assert builder.machine_id == verifier.machine_id

      {:ok, work} = Runners.queue(ctx.card, %{pool: "checkers", kind: "claude", prompt: "Do"})
      {:ok, builder} = Runners.authenticate_machine(ctx.key, builder.id)
      assert %{id: id} = Runners.claim(builder)
      assert id == work.id

      actor = %{
        Actor.unknown()
        | kind: "agent",
          via: "runner",
          user_id: ctx.user.id,
          agent: "builder",
          job_id: work.id
      }

      {:ok, _} =
        Boards.update_card(ctx.card, %{"completed" => true}, actor: actor, by: ctx.user)

      verify =
        Repo.one!(from(j in Runners.Job, where: j.card_id == ^ctx.card.id and j.kind == "verify"))

      assert verify.exclude_runner_id == builder.id

      assert Runners.claim(builder) == nil
      {:ok, verifier} = Runners.authenticate_machine(ctx.key, verifier.id)
      assert %{id: claimed} = Runners.claim(verifier)
      assert claimed == verify.id
    end
  end
end
