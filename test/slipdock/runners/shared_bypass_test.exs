defmodule Slipdock.Runners.SharedBypassTest do
  @moduledoc """
  The warning on a machine's runner set to `bypassPermissions` under the
  `me` executor on a shared board (#3482): given only when all three meet,
  with every way a board is shared, and none for a read-only grant or the
  machine's owner's own.
  """
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Machines, Repo}
  alias Slipdock.Access.Grant
  alias Slipdock.Accounts.Group
  alias Slipdock.Runners.{MachineRunners, SharedBypass}

  @about %{"hostname" => "build-box", "os" => "linux", "arch" => "amd64"}
  @risky %{
    "directory" => "/srv/src/app",
    "permission_mode" => "bypassPermissions",
    "executor" => "me"
  }

  setup do
    owner = user_fixture("bypass-owner@example.com")
    board = board_fixture(%{"name" => "Served"}, owner: owner)
    {:ok, key, _} = Machines.create_enrolment_key(owner, [board.id])
    {:ok, {_key, machine}} = Machines.enrol_with_key(key, @about)
    %{owner: owner, board: board, machine: machine}
  end

  defp runner(ctx, config \\ @risky) do
    {:ok, runner} =
      MachineRunners.add_runner(ctx.machine, ctx.board, %{"pool" => "p", "config" => config})

    runner
  end

  defp grant(attrs), do: Repo.insert!(Grant.changeset(%Grant{}, attrs))

  test "an unshared board: no warning", ctx do
    assert SharedBypass.warnings(runner(ctx)) == []
  end

  test "a comment or write grant to someone else: the warning", ctx do
    for level <- ["comment", "write"] do
      other = user_fixture()
      g = grant(%{level: level, user_id: other.id, board_id: ctx.board.id})
      assert SharedBypass.warnings(runner(ctx)) == [SharedBypass.warning()], level
      Repo.delete!(g)
    end
  end

  test "a read grant, or a grant to the machine's owner: no warning", ctx do
    grant(%{level: "read", user_id: user_fixture().id, board_id: ctx.board.id})
    grant(%{level: "write", user_id: ctx.owner.id, board_id: ctx.board.id})
    assert SharedBypass.warnings(runner(ctx)) == []
  end

  test "a group's grant: the warning", ctx do
    group = Repo.insert!(Group.changeset(%Group{}, %{name: "Crew", owner_id: ctx.owner.id}))
    grant(%{level: "comment", group_id: group.id, board_id: ctx.board.id})
    assert SharedBypass.warnings(runner(ctx)) == [SharedBypass.warning()]
  end

  test "a grant on a sub-board, or on a card in the tree: the warning", ctx do
    epic = card_fixture(hd(ctx.board.columns), %{"title" => "Epic"})
    {:ok, template} = Slipdock.Boards.Templates.find_template(nil, "Simple")
    {:ok, sub} = sub_board(epic, template)
    r = runner(ctx)

    g = grant(%{level: "comment", user_id: user_fixture().id, board_id: sub.id})
    assert SharedBypass.warnings(r) == [SharedBypass.warning()]
    Repo.delete!(g)

    task = card_fixture(hd(Repo.preload(sub, :columns).columns), %{"title" => "Task"})
    g = grant(%{level: "write", user_id: user_fixture().id, card_id: task.id})
    assert SharedBypass.warnings(r) == [SharedBypass.warning()]
    Repo.delete!(g)

    grant(%{level: "write", user_id: user_fixture().id, card_id: epic.id})
    assert SharedBypass.warnings(r) == [SharedBypass.warning()]
  end

  test "a grant on another board: no warning", ctx do
    elsewhere = board_fixture(%{}, owner: ctx.owner)
    grant(%{level: "write", user_id: user_fixture().id, board_id: elsewhere.id})
    assert SharedBypass.warnings(runner(ctx)) == []
  end

  test "permitted email senders: the warning", ctx do
    ctx.board |> Ecto.Changeset.change(inbound_senders: ["someone@example.com"]) |> Repo.update!()
    assert SharedBypass.warnings(runner(ctx)) == [SharedBypass.warning()]
  end

  test "a board someone else owns: the warning", ctx do
    r = runner(ctx)
    ctx.board |> Ecto.Changeset.change(owner_id: user_fixture().id) |> Repo.update!()
    assert SharedBypass.warnings(r) == [SharedBypass.warning()]
  end

  test "a runner with no machine: no warning, even on a shared board", ctx do
    grant(%{level: "write", user_id: user_fixture().id, board_id: ctx.board.id})
    r = runner(ctx)
    assert SharedBypass.warnings(r) == [SharedBypass.warning()]
    assert SharedBypass.warnings(%{r | machine_id: nil}) == []
  end

  test "an unknown owner counts as shared", ctx do
    assert Slipdock.Access.others_write_on_tree?(ctx.board, nil)
    refute Slipdock.Access.others_write_on_tree?(ctx.board, ctx.owner.id)

    r = runner(ctx)
    assert SharedBypass.warnings(r) == []
    assert SharedBypass.warnings(%{r | created_by_id: nil}) == [SharedBypass.warning()]
  end

  test "on a shared board, any other mode or executor: no warning", ctx do
    grant(%{level: "write", user_id: user_fixture().id, board_id: ctx.board.id})

    for {mode, executor} <- [
          {"acceptEdits", "me"},
          {"plan", "me"},
          {"bypassPermissions", "user"},
          {"bypassPermissions", "confined"}
        ] do
      config = %{@risky | "permission_mode" => mode, "executor" => executor}
      assert SharedBypass.warnings(runner(ctx, config)) == [], "#{mode} #{executor}"
    end
  end
end
