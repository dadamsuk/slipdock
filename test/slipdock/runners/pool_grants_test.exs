defmodule Slipdock.Runners.PoolGrantsTest do
  @moduledoc """
  Who takes a runner pool's jobs (#3492): the root board's owner, or a
  writer the owner granted that pool. Granting and taking back; and each
  door that takes a job asking: a session's runner, a machine runner added
  to the pool or moved onto it, and every claim and reclaim a runner
  already in the pool makes. The API and MCP doors are in
  `test/slipdock_web/controllers/api/pool_grants_test.exs`.
  """
  use Slipdock.DataCase, async: true

  import Ecto.Query
  import Slipdock.Fixtures

  alias Slipdock.{Access, Accounts, Actor, Machines, Repo, Runners}
  alias Slipdock.Runners.{Job, MachineRunners, PoolGrants}

  @about %{"hostname" => "pat-box", "os" => "linux", "arch" => "amd64"}

  setup do
    owner = person("owner")
    board = board_fixture(%{"name" => "Pools", "code" => unique_code()}, owner: owner)
    card = card_fixture(hd(board.columns), %{"title" => "Work"})
    writer = person("writer")
    {:ok, _} = Access.grant(board, writer, "write", owner)
    %{owner: owner, board: board, card: card, writer: writer}
  end

  defp person(name), do: user_fixture("#{name}-#{System.unique_integer([:positive])}@example.com")

  defp as(user), do: [actor: Actor.web(user)]

  defp grant!(ctx, pool, user),
    do: {:ok, _} = PoolGrants.grant(ctx.board, pool, user.email, as(ctx.owner))

  defp session(ctx, user, pool) do
    {_, api_token} = Accounts.create_api_token(user, "desk")
    Runners.session_runner(ctx.board, pool, api_token, user)
  end

  defp queue(ctx, pool \\ "dev"),
    do: Runners.queue(ctx.card, %{pool: pool, kind: "claude", prompt: "Do it"})

  describe "may_take?/3" do
    test "the owner takes every pool; a writer only the pools granted them", ctx do
      assert PoolGrants.may_take?(ctx.owner, ctx.board, "dev")
      refute PoolGrants.may_take?(ctx.writer, ctx.board, "dev")

      grant!(ctx, "dev", ctx.writer)

      assert PoolGrants.may_take?(ctx.writer, ctx.board, "dev")
      assert PoolGrants.may_take?(ctx.writer.id, ctx.board.id, " DEV ")
      refute PoolGrants.may_take?(ctx.writer, ctx.board, "verify")
    end

    test "a grant counts on the whole tree, by its root", ctx do
      grant!(ctx, "dev", ctx.writer)
      {:ok, template} = Slipdock.Boards.Templates.find_template(nil, "Simple")
      {:ok, sub} = sub_board(ctx.card, template)

      assert PoolGrants.may_take?(ctx.writer, sub, "dev")
    end

    test "a granted person who can no longer write the board takes nothing", ctx do
      grant!(ctx, "dev", ctx.writer)
      {:ok, _} = Access.grant(ctx.board, ctx.writer, "read", ctx.owner)

      refute PoolGrants.may_take?(ctx.writer, ctx.board, "dev")
    end

    test "nobody, or a person who is gone, takes nothing", ctx do
      refute PoolGrants.may_take?(nil, ctx.board, "dev")
      refute PoolGrants.may_take?(-1, ctx.board, "dev")
    end
  end

  describe "grant/4 and revoke/4" do
    test "only the root board's owner grants or takes back", ctx do
      other = person("other")
      {:ok, _} = Access.grant(ctx.board, other, "write", ctx.owner)

      assert {:error, %Slipdock.Policy.Refused{}} =
               PoolGrants.grant(ctx.board, "dev", other.email, as(ctx.writer))

      grant!(ctx, "dev", other)

      assert {:error, %Slipdock.Policy.Refused{}} =
               PoolGrants.revoke(ctx.board, "dev", other.email, as(ctx.writer))

      assert PoolGrants.may_take?(other, ctx.board, "dev")
    end

    test "the grantee must already write the board", ctx do
      stranger = person("stranger")
      reader = person("reader")
      {:ok, _} = Access.grant(ctx.board, reader, "read", ctx.owner)

      for email <- [stranger.email, reader.email, fixture_email("nobody@example.com")] do
        assert {:error, :invalid, message} =
                 PoolGrants.grant(ctx.board, "dev", email, as(ctx.owner))

        assert message =~ "share it with them first"
      end

      assert {:error, :invalid, _} =
               PoolGrants.grant(ctx.board, "dev", ctx.owner.email, as(ctx.owner))

      assert PoolGrants.list(ctx.board) == []
      refute Accounts.get_user_by_email(fixture_email("nobody@example.com"))
    end

    test "a pool name is checked, and granting twice keeps one grant", ctx do
      assert {:error, :invalid, _} =
               PoolGrants.grant(ctx.board, "no spaces", ctx.writer.email, as(ctx.owner))

      {:ok, first} = PoolGrants.grant(ctx.board, "Dev", ctx.writer.email, as(ctx.owner))
      {:ok, again} = PoolGrants.grant(ctx.board, "dev", ctx.writer.email, as(ctx.owner))

      assert first.id == again.id
      assert first.granted_by_id == ctx.owner.id
      assert [%{pool: "dev", user: %{id: id}}] = PoolGrants.list(ctx.board)
      assert id == ctx.writer.id
    end

    test "taking it back stops the grant; one that isn't there is not found", ctx do
      grant!(ctx, "dev", ctx.writer)

      assert :ok = PoolGrants.revoke(ctx.board, "dev", ctx.writer.email, as(ctx.owner))
      refute PoolGrants.may_take?(ctx.writer, ctx.board, "dev")

      assert {:error, :not_found} =
               PoolGrants.revoke(ctx.board, "dev", ctx.writer.email, as(ctx.owner))
    end
  end

  describe "a session's runner" do
    test "a writer with no grant is refused, saying why", ctx do
      assert {:error, :forbidden, message} = session(ctx, ctx.writer, "dev")
      assert message =~ "pool “dev”"
      assert message =~ "owner"
    end

    test "the owner, and a writer granted the pool, take its jobs", ctx do
      {:ok, job} = queue(ctx)
      grant!(ctx, "dev", ctx.writer)

      assert {:ok, theirs} = session(ctx, ctx.writer, "dev")
      assert %{id: id} = Runners.claim(theirs)
      assert id == job.id

      {:ok, job2} = queue(ctx)
      assert {:ok, mine} = session(ctx, ctx.owner, "dev")
      assert %{id: id2} = Runners.claim(mine)
      assert id2 == job2.id
    end

    test "once the grant goes, a session runner already made takes nothing", ctx do
      grant!(ctx, "dev", ctx.writer)
      {:ok, runner} = session(ctx, ctx.writer, "dev")
      :ok = PoolGrants.revoke(ctx.board, "dev", ctx.writer.email, as(ctx.owner))
      {:ok, job} = queue(ctx)

      assert Runners.claim(runner) == nil
      assert Repo.get!(Job, job.id).status == "queued"
    end

    test "nor does it take back a job it held once its grant is gone", ctx do
      grant!(ctx, "dev", ctx.writer)
      {:ok, runner} = session(ctx, ctx.writer, "dev")
      {:ok, job} = queue(ctx)
      assert %{id: id} = Runners.claim(runner)
      assert id == job.id

      # Its lease runs out and the sweep puts it back.
      past = DateTime.utc_now() |> DateTime.add(-3600) |> DateTime.truncate(:second)
      Repo.update_all(from(j in Job, where: j.id == ^job.id), set: [lease_expires_at: past])
      Runners.sweep()
      assert Repo.get!(Job, job.id).status == "queued"

      :ok = PoolGrants.revoke(ctx.board, "dev", ctx.writer.email, as(ctx.owner))

      assert {:error, :not_found} = Runners.heartbeat(runner, job.id, "", %{})
      assert Repo.get!(Job, job.id).status == "queued"
    end
  end

  describe "a machine's runner" do
    setup ctx do
      {:ok, key, _} = Machines.create_enrolment_key(ctx.writer, [ctx.board.id])
      {:ok, {_machine_key, machine}} = Machines.enrol_with_key(key, @about)
      %{machine: machine}
    end

    defp add(ctx, pool),
      do:
        MachineRunners.add_runner(ctx.machine, ctx.board, %{
          "pool" => pool,
          "config" => %{"directory" => "/srv/src/app"}
        })

    test "a writer's machine can't join a pool they weren't granted", ctx do
      assert {:error, :invalid, message} = add(ctx, "dev")
      assert message =~ "pool “dev”"
    end

    test "granted, it joins and takes the pool's jobs", ctx do
      grant!(ctx, "dev", ctx.writer)
      {:ok, job} = queue(ctx)

      assert {:ok, runner} = add(ctx, "dev")
      assert %{id: id} = Runners.claim(runner)
      assert id == job.id
    end

    test "it can't be moved onto a pool it wasn't granted, but stays settable", ctx do
      grant!(ctx, "dev", ctx.writer)
      {:ok, runner} = add(ctx, "dev")

      assert {:error, :invalid, _} = MachineRunners.set_runner(runner, %{"pool" => "verify"})

      assert {:ok, renamed} =
               MachineRunners.set_runner(runner, %{"name" => "kept", "pool" => "dev"})

      assert renamed.name == "kept"
    end

    test "one already in the pool is kept, but takes nothing until granted again", ctx do
      grant!(ctx, "dev", ctx.writer)
      {:ok, runner} = add(ctx, "dev")
      :ok = PoolGrants.revoke(ctx.board, "dev", ctx.writer.email, as(ctx.owner))
      {:ok, job} = queue(ctx)

      assert Runners.claim(runner) == nil
      assert Repo.get!(Job, job.id).status == "queued"
      assert Repo.get(Runners.Runner, runner.id)

      grant!(ctx, "dev", ctx.writer)
      assert %{id: id} = Runners.claim(runner)
      assert id == job.id
    end
  end

  test "a runner with a token of its own, made by the owner, still takes jobs", ctx do
    {:ok, runner, _} =
      Runners.create_runner(ctx.board, %{"name" => "m", "pool" => "dev"}, ctx.owner)

    {:ok, legacy, _} = Runners.create_runner(ctx.board, %{"name" => "n", "pool" => "dev"})
    {:ok, job} = queue(ctx)
    {:ok, job2} = queue(ctx)

    assert %{id: id} = Runners.claim(runner)
    assert %{id: id2} = Runners.claim(legacy)
    assert Enum.sort([id, id2]) == Enum.sort([job.id, job2.id])
  end
end
