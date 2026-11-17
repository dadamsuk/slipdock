defmodule Slipdock.MachineBoardsTest do
  @moduledoc """
  Changing the boards an enrolled machine serves (#3249), without
  re-enrolling it: added and removed by its owner, each change in the
  machine's changes and out in its config at once; refused for a board the
  owner can't serve, a board with runners still on it (named), the last
  board and a revoked machine; and where the server's boards and the
  machine's own ceiling disagree.
  """
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Machines, Repo}
  alias Slipdock.Machines.Machine
  alias Slipdock.Runners.{ConfigReport, MachineRunners}

  @about %{"hostname" => "build-box", "os" => "linux", "arch" => "amd64"}

  setup do
    user = user_fixture()
    first = board_fixture(%{"name" => "First", "code" => unique_code()}, owner: user)
    second = board_fixture(%{"name" => "Second", "code" => unique_code()}, owner: user)
    {:ok, key, _} = Machines.create_enrolment_key(user, [first.id])
    {:ok, {_machine_key, machine}} = Machines.enrol_with_key(key, @about)
    %{user: user, first: first, second: second, machine: machine}
  end

  defp runner(machine, board, name) do
    {:ok, runner} =
      MachineRunners.add_runner(machine, board, %{
        "pool" => "build",
        "name" => name,
        "config" => %{"directory" => "/srv/src/app"}
      })

    runner
  end

  defp fresh(machine), do: Repo.get!(Machine, machine.id)

  describe "adding a board" do
    test "the machine serves it at once, its runners untouched, and the change is logged",
         ctx do
      builder = runner(ctx.machine, ctx.first, "builder")
      before = fresh(ctx.machine).config_version

      assert {:ok, machine} =
               Machines.change_boards(ctx.machine, ctx.user, add: [ctx.second.code])

      assert machine.board_ids == [ctx.first.id, ctx.second.id]
      assert machine.revoked_at == nil
      assert machine.config_version == before + 1

      # The first board's runner is as it was.
      assert [%{id: id, config_version: 1}] = MachineRunners.list_runners(machine)
      assert id == builder.id

      assert [%ConfigReport{outcome: "board_added", runner_id: nil, reason: reason, version: v}] =
               MachineRunners.reports(machine)

      assert reason == "Second (##{ctx.second.id})"
      assert v == machine.config_version
    end

    test "the daemon's config then carries the new board's runners", ctx do
      {:ok, machine} = Machines.change_boards(ctx.machine, ctx.user, add: [ctx.second.id])

      # Before, a runner for the board was refused; now it is added.
      second_runner = runner(machine, ctx.second, "second")

      config = MachineRunners.config_for(machine)
      assert config.boards == [ctx.first.id, ctx.second.id]

      assert Enum.any?(
               config.runners,
               &(&1.id == second_runner.id and &1.board_id == ctx.second.id)
             )

      # The long-poll from the version before the change answers at once.
      assert %{boards: [_, _]} =
               MachineRunners.wait_for_config(machine, machine.config_version - 2, 0)
    end

    test "a board the owner can't write to is refused, and nothing changes", ctx do
      stranger = user_fixture("stranger@example.com")
      theirs = board_fixture(%{"name" => "Theirs"}, owner: stranger)

      assert {:error, :invalid, "not a top-level board you can write to: " <> named} =
               Machines.change_boards(ctx.machine, ctx.user, add: [theirs.id])

      assert named == Integer.to_string(theirs.id)

      # A board they can only read is refused too: serving one writes to it.
      {:ok, _} = Slipdock.Access.grant(theirs, ctx.user, "read", stranger)

      assert {:error, :invalid, _} =
               Machines.change_boards(ctx.machine, ctx.user, add: [theirs.id])

      assert fresh(ctx.machine).board_ids == [ctx.first.id]
      assert MachineRunners.reports(ctx.machine) == []
    end

    test "a board already served changes nothing and logs nothing", ctx do
      version = fresh(ctx.machine).config_version

      assert {:ok, machine} = Machines.change_boards(ctx.machine, ctx.user, add: [ctx.first.id])
      assert machine.board_ids == [ctx.first.id]
      assert fresh(machine).config_version == version
      assert MachineRunners.reports(machine) == []
    end
  end

  describe "removing a board" do
    setup ctx do
      {:ok, machine} = Machines.change_boards(ctx.machine, ctx.user, add: [ctx.second.id])
      %{machine: machine}
    end

    test "the machine stops serving it, and the change is logged", ctx do
      builder = runner(ctx.machine, ctx.first, "builder")

      assert {:ok, machine} =
               Machines.change_boards(ctx.machine, ctx.user, remove: [ctx.second.id])

      assert machine.board_ids == [ctx.first.id]
      assert [%{id: id}] = MachineRunners.list_runners(machine)
      assert id == builder.id

      assert [%{outcome: "board_removed", reason: reason}, %{outcome: "board_added"}] =
               MachineRunners.reports(machine)

      assert reason == "Second (##{ctx.second.id})"
      assert MachineRunners.config_for(machine).boards == [ctx.first.id]
    end

    test "a board with runners on this machine is refused, naming them", ctx do
      a = runner(ctx.machine, ctx.second, "builder")
      b = runner(ctx.machine, ctx.second, "verifier")

      assert {:error, :invalid, message} =
               Machines.change_boards(ctx.machine, ctx.user, remove: [ctx.second.id])

      assert message =~ "board ##{ctx.second.id} still has runners on this machine"
      assert message =~ "builder (##{a.id})"
      assert message =~ "verifier (##{b.id})"
      assert message =~ "Remove them first"

      assert fresh(ctx.machine).board_ids == [ctx.first.id, ctx.second.id]
      assert length(MachineRunners.list_runners(ctx.machine)) == 2

      # Once they are removed, the board goes.
      {:ok, _} = MachineRunners.remove_runner(a)
      {:ok, _} = MachineRunners.remove_runner(b)

      assert {:ok, %{board_ids: [_]}} =
               Machines.change_boards(ctx.machine, ctx.user, remove: [ctx.second.id])
    end

    test "the last board is refused: revoke the machine instead", ctx do
      {:ok, machine} = Machines.change_boards(ctx.machine, ctx.user, remove: [ctx.second.id])

      assert {:error, :invalid, "a machine serves at least one board" <> _} =
               Machines.change_boards(machine, ctx.user, remove: [ctx.first.id])

      assert fresh(machine).board_ids == [ctx.first.id]
    end

    test "a board the machine doesn't serve is refused", ctx do
      other = board_fixture(%{"name" => "Other"}, owner: ctx.user)

      assert {:error, :invalid, "the machine doesn't serve " <> _} =
               Machines.change_boards(ctx.machine, ctx.user, remove: [other.id])
    end

    test "a board the owner can no longer reach can still be removed: it only narrows", ctx do
      stranger = user_fixture("stranger@example.com")
      shared = board_fixture(%{"name" => "Shared"}, owner: stranger)
      {:ok, grant} = Slipdock.Access.grant(shared, ctx.user, "write", stranger)
      {:ok, machine} = Machines.change_boards(ctx.machine, ctx.user, add: [shared.id])
      {:ok, _} = Slipdock.Access.revoke(grant)
      refute shared.id in Enum.map(Machines.servable_boards(ctx.user), & &1.id)

      assert {:ok, machine} = Machines.change_boards(machine, ctx.user, remove: [shared.id])
      refute shared.id in machine.board_ids
    end
  end

  describe "two changes from the same stale copy (#3347)" do
    setup ctx do
      {:ok, machine} = Machines.change_boards(ctx.machine, ctx.user, add: [ctx.second.id])
      third = board_fixture(%{"name" => "Third", "code" => unique_code()}, owner: ctx.user)
      %{stale: machine, third: third}
    end

    test "one adds a board, the other removes one: both survive", ctx do
      assert {:ok, _} = Machines.change_boards(ctx.stale, ctx.user, add: [ctx.third.id])

      assert {:ok, machine} =
               Machines.change_boards(ctx.stale, ctx.user, remove: [ctx.second.id])

      assert machine.board_ids == [ctx.first.id, ctx.third.id]
      assert fresh(ctx.machine).board_ids == [ctx.first.id, ctx.third.id]

      assert [%{outcome: "board_removed"}, %{outcome: "board_added"}, %{outcome: "board_added"}] =
               MachineRunners.reports(machine)
    end

    test "both add a board: both survive", ctx do
      fourth = board_fixture(%{"name" => "Fourth", "code" => unique_code()}, owner: ctx.user)

      assert {:ok, _} = Machines.change_boards(ctx.stale, ctx.user, add: [ctx.third.id])
      assert {:ok, machine} = Machines.change_boards(ctx.stale, ctx.user, add: [fourth.id])

      assert machine.board_ids == [ctx.first.id, ctx.second.id, ctx.third.id, fourth.id]
    end

    test "a board the stale copy doesn't show yet can be removed", ctx do
      {:ok, _} = Machines.change_boards(ctx.stale, ctx.user, add: [ctx.third.id])

      assert {:ok, machine} = Machines.change_boards(ctx.stale, ctx.user, remove: [ctx.third.id])
      assert machine.board_ids == [ctx.first.id, ctx.second.id]
    end

    test "removing what the other already removed is refused, changing nothing", ctx do
      {:ok, _} = Machines.change_boards(ctx.stale, ctx.user, remove: [ctx.second.id])
      version = fresh(ctx.machine).config_version

      assert {:error, :invalid, "the machine doesn't serve " <> _} =
               Machines.change_boards(ctx.stale, ctx.user, remove: [ctx.second.id])

      machine = fresh(ctx.machine)
      assert machine.board_ids == [ctx.first.id]
      assert machine.config_version == version
    end

    test "the last board is refused against the machine as it is now", ctx do
      {:ok, _} = Machines.change_boards(ctx.stale, ctx.user, remove: [ctx.second.id])

      assert {:error, :invalid, "a machine serves at least one board" <> _} =
               Machines.change_boards(ctx.stale, ctx.user, remove: [ctx.first.id])

      assert fresh(ctx.machine).board_ids == [ctx.first.id]
    end

    test "a runner added since the copy was read still stops its board going", ctx do
      builder = runner(fresh(ctx.machine), ctx.second, "builder")

      assert {:error, :invalid, message} =
               Machines.change_boards(ctx.stale, ctx.user, remove: [ctx.second.id])

      assert message =~ "builder (##{builder.id})"
      assert fresh(ctx.machine).board_ids == [ctx.first.id, ctx.second.id]
    end

    test "the write that sets the boards makes the runner check itself", ctx do
      runner(ctx.stale, ctx.second, "builder")
      version = fresh(ctx.machine).config_version

      assert {:error, :invalid, "board " <> _} =
               MachineRunners.set_boards(ctx.stale, [], [ctx.second.id])

      machine = fresh(ctx.machine)
      assert machine.board_ids == [ctx.first.id, ctx.second.id]
      assert machine.config_version == version
    end

    test "a runner can't be added from a stale copy to a board since removed", ctx do
      {:ok, _} = Machines.change_boards(ctx.stale, ctx.user, remove: [ctx.second.id])

      assert {:error, :invalid, "the machine doesn't serve that board" <> _} =
               MachineRunners.add_runner(ctx.stale, ctx.second, %{
                 "pool" => "build",
                 "name" => "late",
                 "config" => %{"directory" => "/srv/src/app"}
               })

      assert MachineRunners.list_runners(ctx.machine) == []
    end
  end

  describe "refused outright" do
    test "a revoked machine, nothing named, and a board both added and removed", ctx do
      assert {:error, :invalid, "name a board to add or to remove"} =
               Machines.change_boards(ctx.machine, ctx.user, add: [], remove: [" "])

      assert {:error, :invalid, "board " <> _} =
               Machines.change_boards(ctx.machine, ctx.user,
                 add: [ctx.first.id],
                 remove: [ctx.first.id]
               )

      {:ok, revoked} = Machines.revoke_machine(ctx.machine)

      assert {:error, :invalid, "the machine is revoked"} =
               Machines.change_boards(revoked, ctx.user, add: [ctx.second.id])
    end
  end

  describe "the ceiling mismatch" do
    test "boards allowed here but not in the machine's ceiling, and the reverse", ctx do
      assert Machines.ceiling_mismatch(ctx.machine) == %{missing: [], extra: []}

      {:ok, machine} =
        MachineRunners.record_ceiling(ctx.machine, %{
          "roots" => ["/srv/src"],
          "agents" => ["claude"],
          "executors" => ["user"],
          "boards" => [ctx.first.id, 999],
          "max_permission_mode" => "acceptEdits",
          "max_timeout_minutes" => 60
        })

      {:ok, machine} = Machines.change_boards(machine, ctx.user, add: [ctx.second.id])

      assert Machines.ceiling_mismatch(machine) == %{missing: [ctx.second.id], extra: [999]}

      # Its runner is marked as one the machine will refuse.
      second_runner = runner(machine, ctx.second, "second")

      assert {:error, ["board #{ctx.second.id} is not one this machine serves"]} ==
               MachineRunners.outside_ceiling(machine, second_runner)
    end
  end
end
