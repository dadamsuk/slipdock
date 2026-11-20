defmodule Slipdock.Automations.Scheduler.Leader do
  @moduledoc """
  Which node's scheduler runs the ticks (#3496): the one holding a Postgres
  session advisory lock, on a connection of its own outside the repo's pool
  so that nothing else checks it out and the lock lives exactly as long as
  the connection.

  `leading?/1` takes the lock if it is free and says whether this
  connection holds it. It never takes it twice: a lock already held is seen
  in `pg_locks`, so the session's count stays at one and closing the
  connection always frees it. A connection that dropped and came back has
  lost the lock with its session, and takes it again only if no other node
  got there first. The lock goes when the node does: its connection closes
  and Postgres ends the session. A node cut off without its socket closing
  keeps it until the kernel's TCP keepalive gives up, so the connection
  turns keepalive on.
  """

  require Logger

  # The two-key form, so it is matched exactly in `pg_locks` (`objsubid` 2).
  # 7_401: the scheduler's; 7_400 is the automation rules' per-rule locks.
  @default_lock {7_401, 1}

  @doc "The lock the node's own scheduler leads by."
  def default_lock, do: @default_lock

  @doc """
  Opens the connection the lock is held on, linked to the caller, and
  returns it with the lock, for `leading?/1`. It connects in the background and reconnects by itself.
  """
  def start_link({_, _} = lock) do
    {:ok, conn} =
      Slipdock.Repo.config()
      |> Keyword.drop([:pool, :pool_size, :name, :telemetry_prefix, :log])
      |> Keyword.update(:socket_options, [keepalive: true], &[{:keepalive, true} | &1])
      |> Keyword.merge(pool_size: 1, backoff_type: :exp)
      |> Postgrex.start_link()

    {conn, lock}
  end

  @doc """
  Whether the connection from `start_link/1` holds the lock, taking it if
  it is free. `false` while the database can't be reached.
  """
  def leading?({conn, {key1, key2}}) do
    %{rows: [[held]]} =
      Postgrex.query!(
        conn,
        """
        SELECT CASE
          WHEN EXISTS (
            SELECT 1 FROM pg_locks
            WHERE locktype = 'advisory' AND granted AND pid = pg_backend_pid()
              AND classid = $1::int4::oid AND objid = $2::int4::oid AND objsubid = 2
          ) THEN true
          ELSE pg_try_advisory_lock($1::int4, $2::int4)
        END
        """,
        [key1, key2]
      )

    held
  rescue
    error ->
      Logger.warning("Automation scheduler: can't check the lead: #{Exception.message(error)}")
      false
  end
end
