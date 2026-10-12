defmodule SlipdockCLI.Sync.Watch do
  @moduledoc false

  # `slipdock sync --watch` (W-103 R2.1, R2.7): a pass whenever either side
  # has something to say, and not before.
  #
  #   * **Here.** The folder is looked at every second — names, sizes and
  #     times only, so it costs nothing when nothing moved. A change starts a
  #     2 s clock, and every further change restarts it; the pass runs once
  #     the folder has been still that long. An editor that saves through a
  #     temp file and a rename has finished by then, and the temp file was
  #     never synced anyway (`SlipdockCLI.Sync.Scan`).
  #   * **There.** The change feed is asked every `interval` seconds from
  #     the state's cursor. Anything new, or `resync`, runs a pass (which
  #     lists the vault whole, so a resync needs nothing more).
  #
  # A pass that fails — the server down, the network gone — is said once
  # and tried again on the next tick that has reason to, never in a loop.

  alias SlipdockCLI.Sync.Scan

  @settle_ms 2_000

  def settle_ms, do: @settle_ms

  @doc """
  A watcher's starting point: `snapshot` is the folder as of the last pass
  (path → `{size, mtime}`).
  """
  def new(snapshot, now_ms),
    do: %{snapshot: snapshot, changed_at: nil, polled_at: now_ms, dirty: false}

  @doc "The folder's names, sizes and times: what a tick compares."
  def snapshot(root) do
    root |> Scan.scan_stats() |> Map.new(fn {path, stat} -> {path, {stat.size, stat.mtime}} end)
  end

  @doc """
  One tick: given the folder as it is now and the time, what to do —
  `{:pass, watch}` to sync now, `{:poll, watch}` to ask the change feed, or
  `{:idle, watch}`. Pure, so the timing rules are tested without a clock.
  """
  def tick(watch, current, now_ms, opts \\ []) do
    settle = Keyword.get(opts, :settle_ms, @settle_ms)
    interval = Keyword.get(opts, :interval_ms, 10_000)

    watch =
      cond do
        current != watch.snapshot and current != Map.get(watch, :last_seen) ->
          %{watch | changed_at: now_ms, dirty: true} |> Map.put(:last_seen, current)

        true ->
          watch
      end

    cond do
      watch.dirty and now_ms - watch.changed_at >= settle ->
        {:pass, watch}

      not watch.dirty and now_ms - watch.polled_at >= interval ->
        {:poll, %{watch | polled_at: now_ms}}

      true ->
        {:idle, watch}
    end
  end

  @doc "After a pass: the folder as it now stands is the new still point."
  def passed(watch, snapshot, now_ms),
    do:
      %{watch | snapshot: snapshot, changed_at: nil, dirty: false, polled_at: now_ms}
      |> Map.put(:last_seen, snapshot)

  @doc """
  Whether a change-feed answer means a pass: anything changed since the
  cursor, or the cursor is too old to follow.
  """
  def changed?({:ok, %{"resync" => true}}), do: true
  def changed?({:ok, %{"changes" => [_ | _]}}), do: true
  def changed?(_), do: false

  @doc """
  Runs forever: `pass` is called with no arguments and returns the cursor it
  left (or nil when it failed); `poll` is called with that cursor and
  returns the feed's answer. `:ticks` stops it after that many (for tests).
  """
  def loop(root, cursor, pass, poll, opts \\ []) do
    sleep = Keyword.get(opts, :sleep, &Process.sleep/1)
    clock = Keyword.get(opts, :clock, fn -> System.monotonic_time(:millisecond) end)
    watch = new(snapshot(root), clock.())

    do_loop(
      root,
      watch,
      cursor,
      pass,
      poll,
      sleep,
      clock,
      opts,
      Keyword.get(opts, :ticks, :infinity)
    )
  end

  defp do_loop(_root, _watch, cursor, _pass, _poll, _sleep, _clock, _opts, 0), do: cursor

  defp do_loop(root, watch, cursor, pass, poll, sleep, clock, opts, ticks) do
    sleep.(1_000)
    now = clock.()

    {watch, cursor} =
      case tick(watch, snapshot(root), now, opts) do
        {:pass, watch} ->
          {passed(watch, snapshot(root), clock.()), pass.() || cursor}

        {:poll, watch} ->
          if changed?(poll.(cursor)),
            do: {passed(watch, snapshot(root), clock.()), pass.() || cursor},
            else: {watch, cursor}

        {:idle, watch} ->
          {watch, cursor}
      end

    do_loop(root, watch, cursor, pass, poll, sleep, clock, opts, dec(ticks))
  end

  defp dec(:infinity), do: :infinity
  defp dec(n), do: n - 1
end
