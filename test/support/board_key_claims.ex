defmodule Slipdock.BoardKeyClaims do
  @moduledoc """
  Which board codes and shortcuts the tests running right now hold.

  A test's boards sit in a sandbox transaction no other test can see, so two
  async tests deriving a key from the same name ("Epic", "Ship it") both find
  it free, and the second insert waits on the first's uncommitted board until
  that test ends. Past 15 seconds it is cancelled, failing some test in its
  setup (#830). `Slipdock.Boards` asks this module (through the
  `:board_key_claims` setting, which only the test config sets) before it
  derives a key, and passes over one that another running test holds.

  A claim belongs to the test's sandbox owner, so it lasts exactly as long as
  the transaction its board is in, and is let go when the owner stops.
  """

  @table __MODULE__

  @doc "Creates the table. Called once, from `test/test_helper.exs`."
  def start do
    :ets.new(@table, [:set, :public, :named_table])
    :ok
  end

  @doc """
  Records `owner` (the sandbox owner) as the holder of anything `test` claims,
  and of anything a process it started claims. Called by `Slipdock.DataCase`.
  """
  def register_test(test, owner), do: :ets.insert(@table, {{:test, test}, owner})

  @doc """
  Claims `value` for the calling test unless another running test holds it.
  True when the calling test now holds it (or already did); false when it is
  somebody else's. `kind` is `:code` or `:shortcut`.
  """
  def claim(kind, value) do
    me = holder()

    case take({kind, value}, me) do
      :new -> true
      :ours -> true
      :theirs -> false
    end
  end

  @doc """
  Claims `value` only if nobody, the calling test included, holds it yet: for
  handing out a key that has to be new to this test as well.
  """
  def claim_new(kind, value), do: take({kind, value}, holder()) == :new

  defp take(key, me) do
    if :ets.insert_new(@table, {key, me}) do
      :new
    else
      case :ets.lookup(@table, key) do
        [{_, ^me}] ->
          :ours

        [{_, pid}] ->
          # A test that has ended has let its claims go.
          if not Process.alive?(pid) and
               :ets.select_replace(@table, [{{key, pid}, [], [{{{:const, key}, me}}]}]) == 1,
             do: :new,
             else: :theirs

        [] ->
          take(key, me)
      end
    end
  end

  # The sandbox owner of the test this process works for: the test itself, or
  # a LiveView, task or other process it started (which carry the test in
  # `$callers`). A process that belongs to no test holds its own claims.
  defp holder do
    [self() | Process.get(:"$callers", [])]
    |> Enum.find_value(fn pid ->
      case :ets.lookup(@table, {:test, pid}) do
        [{_, owner}] -> owner
        [] -> nil
      end
    end) || self()
  end

  @doc """
  The next value of the counter `name`, for handing keys out in turn.
  """
  def next(name), do: :ets.update_counter(@table, {:counter, name}, 1, {{:counter, name}, -1})
end
