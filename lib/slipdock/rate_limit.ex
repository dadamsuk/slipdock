defmodule Slipdock.RateLimit do
  @moduledoc """
  A counter per key per window, in one ETS table, for the handful of places
  that must not be hammered: the sign-in form above all, which otherwise lets
  anyone make this server email arbitrary addresses as fast as they can post.

  Deliberately small. Fixed windows rather than a sliding log — the point is
  to stop a flood, not to meter billing — and no new dependency.

      case Slipdock.RateLimit.hit("login:ip:1.2.3.4", 20, :timer.hours(1)) do
        :ok -> ...
        {:error, seconds} -> "Try again in \#{seconds}s"
      end

  Counts live in this node's memory only, so a restart forgives everyone and a
  second node counts separately. For a self-hosted single-node app that is the
  right trade; anything stricter wants a shared store.

  `config :slipdock, :rate_limit, enabled: false` turns it off, which is what
  the test environment does except where a test is about this module.
  """

  use GenServer

  @table __MODULE__

  @doc """
  Records one use of `key` and says whether it is allowed: `:ok`, or
  `{:error, seconds}` with how long until the window resets.

  `limit` is how many uses are allowed per `window_ms`.
  """
  @spec hit(String.t(), pos_integer(), pos_integer()) :: :ok | {:error, non_neg_integer()}
  def hit(key, limit, window_ms) do
    if enabled?() do
      now = System.system_time(:millisecond)
      window = div(now, window_ms)
      resets_at = (window + 1) * window_ms
      # The expiry rides along in the row so the sweep can compare rows from
      # different window sizes, which bare window numbers cannot be.
      count = :ets.update_counter(@table, {key, window}, {2, 1}, {{key, window}, 0, resets_at})

      if count <= limit do
        :ok
      else
        {:error, div(resets_at - now, 1000) + 1}
      end
    else
      :ok
    end
  end

  @doc """
  How many uses of `key` are left in the current window, without recording
  one. For telling someone where they stand, not for deciding.
  """
  @spec remaining(String.t(), pos_integer(), pos_integer()) :: non_neg_integer()
  def remaining(key, limit, window_ms) do
    window = div(System.system_time(:millisecond), window_ms)

    case :ets.lookup(@table, {key, window}) do
      [{_, count, _resets_at}] -> max(limit - count, 0)
      [] -> limit
    end
  end

  @doc "Forgets every count. For tests, and for a human who has locked themselves out."
  def reset do
    if :ets.whereis(@table) != :undefined, do: :ets.delete_all_objects(@table)
    :ok
  end

  def enabled?, do: Slipdock.Config.get(:rate_limit, [])[:enabled] != false

  # ── the table ──────────────────────────────────────────────────────────

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, write_concurrency: true])
    # Old windows are dead weight, not state: sweep them rather than letting
    # the table grow with every address anybody ever tried.
    :timer.send_interval(:timer.minutes(10), :sweep)
    {:ok, %{}}
  end

  @impl true
  def handle_info(:sweep, state) do
    # A window that has already reset can never be read again.
    now = System.system_time(:millisecond)
    :ets.select_delete(@table, [{{:_, :_, :"$1"}, [{:<, :"$1", now}], [true]}])
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}
end
