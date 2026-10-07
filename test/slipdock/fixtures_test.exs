defmodule Slipdock.FixturesTest do
  @moduledoc """
  The fixtures async tests share. Each async test runs in an uncommitted
  sandbox transaction, so anything a fixture writes to a unique index can make
  one test wait on another — and, held the other way round, deadlock (#352).
  """
  use ExUnit.Case, async: true

  alias Ecto.Adapters.SQL.Sandbox
  alias Slipdock.Repo
  import Slipdock.Fixtures

  # Runs `fun` in a sandbox transaction of its own, the way a separate async
  # test would, and keeps that transaction open until told to finish.
  defp in_own_sandbox(fun, lock_timeout \\ nil) do
    parent = self()

    Task.async(fn ->
      owner = Sandbox.start_owner!(Repo)

      try do
        if lock_timeout, do: Repo.query!("SET LOCAL lock_timeout = '#{lock_timeout}'")
        send(parent, {:done, self(), fun.()})

        receive do
          :finish -> :ok
        end
      after
        Sandbox.stop_owner(owner)
      end
    end)
  end

  # Never the shared default user: an open transaction holding that row would
  # make every other test that wants it wait.
  defp owner, do: user_fixture("fixtures-#{System.unique_integer([:positive])}@example.com")

  defp result(task) do
    pid = task.pid

    receive do
      {:done, ^pid, value} -> value
    after
      30_000 -> flunk("the fixture never returned")
    end
  end

  defp finish(task) do
    send(task.pid, :finish)
    Task.await(task)
  end

  test "same-named boards in two open transactions don't wait on each other" do
    a =
      in_own_sandbox(
        fn -> board_fixture(%{"name" => "Private"}, owner: owner()) end,
        "2s"
      )

    first = result(a)

    # Without unique keys this insert waits on `a`'s uncommitted `private`/`p`
    # until lock_timeout gives up, and board_fixture's match fails.
    b =
      in_own_sandbox(
        fn -> board_fixture(%{"name" => "Private"}, owner: owner()) end,
        "2s"
      )

    second = result(b)

    assert first.code != second.code
    assert first.shortcut != second.shortcut
    assert String.length(second.shortcut) == 2

    finish(a)
    finish(b)
  end

  test "a code or shortcut the test names is kept" do
    board =
      in_own_sandbox(fn ->
        board_fixture(%{"name" => "Named", "code" => "fx-named", "shortcut" => "zq"},
          owner: owner()
        )
      end)

    assert %{code: "fx-named", shortcut: "zq"} = result(board)
    finish(board)
  end

  test "derive_keys: true takes them from the name, as the app does" do
    board =
      in_own_sandbox(fn ->
        board_fixture(%{"name" => "Xylo Fixture"}, owner: owner(), derive_keys: true)
      end)

    assert %{code: "xylo-fixtu", shortcut: "x"} = result(board)
    finish(board)
  end
end
