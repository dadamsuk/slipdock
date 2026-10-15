defmodule Slipdock.TestRunLock do
  @moduledoc """
  One `mix test` run at a time per test database.

  Every run hands out the same fixture values: `System.unique_integer/1` and
  the shortcut counter start again in each VM, so two runs at once (parallel
  sessions in one checkout) both make board `fx1` with shortcut `aa`, and the
  second insert waits on the first run's open sandbox transaction until that
  test ends. Past 15 seconds the insert is cancelled, and some test fails in
  its setup (#830). Board shortcuts are two characters, so the values can't be
  made unique per run; the runs take turns instead.

  The lock is a session-level advisory lock held by a connection of its own,
  outside the sandbox, for as long as the VM lives. It goes when the run ends,
  however it ends, because Postgres drops it with the connection. A run that
  wants to go alongside rather than wait uses a database of its own with
  `MIX_TEST_PARTITION`.
  """

  # The first half of the lock's two-part key, the second being `:key`.
  # `Slipdock.Automations` uses 7_400 for its own locks.
  @class 7_401

  @doc """
  Takes the lock, waiting for whoever has it, and returns the connection
  holding it. `on_wait` is called with the database name before waiting.

  Options: `:config` (connection settings, the repo's by default), `:key`
  (0 by default, the one the suite takes) and `:on_wait`.
  """
  def hold(opts \\ []) do
    config = Keyword.get_lazy(opts, :config, &Slipdock.Repo.config/0)
    key = Keyword.get(opts, :key, 0)
    on_wait = Keyword.get(opts, :on_wait, &notice/1)

    {:ok, conn} =
      config
      |> Keyword.take([:hostname, :port, :username, :password, :database, :socket_dir, :ssl])
      |> Keyword.put(:pool_size, 1)
      |> Postgrex.start_link()

    # Owned by nobody in particular: the lock lasts as long as the VM.
    Process.unlink(conn)

    %{rows: [[locked?]]} =
      Postgrex.query!(conn, "SELECT pg_try_advisory_lock($1, $2)", [@class, key])

    unless locked? do
      on_wait.(config[:database])
      Postgrex.query!(conn, "SELECT pg_advisory_lock($1, $2)", [@class, key], timeout: :infinity)
    end

    {:ok, conn}
  end

  defp notice(database) do
    IO.puts(
      :stderr,
      "Another mix test run is using #{database}; waiting for it to finish. " <>
        "Set MIX_TEST_PARTITION=2 (or any number) to use a database of your own instead."
    )
  end
end
