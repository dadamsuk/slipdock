defmodule Slipdock.Deferred do
  @moduledoc """
  Side effects held back until a transaction has committed.

  A write made through the ordinary functions (`Slipdock.Boards.create_card/3`
  and the rest) also tells people — mention emails — and runs automation
  rules. Inside a transaction that may yet roll back (a meeting capture's
  commit, its undo), those must not happen until the rows they are about are
  certainly there, and must not happen at all if they are not.

  `collect/1` runs a function with effects held back in this process, and
  hands back the result and what was held; `run/1` lets them go. Outside
  `collect/1`, `defer/1` just runs its function.
  """

  @key {__MODULE__, :effects}

  @doc "Runs `fun` with side effects held back: `{result, effects}`."
  def collect(fun) when is_function(fun, 0) do
    outer = Process.get(@key)
    Process.put(@key, [])

    try do
      result = fun.()
      {result, Enum.reverse(Process.get(@key, []))}
    after
      if outer, do: Process.put(@key, outer), else: Process.delete(@key)
    end
  end

  @doc "Whether this process is holding side effects back."
  def collecting?, do: is_list(Process.get(@key))

  @doc "Holds `fun` back when collecting; otherwise runs it now."
  def defer(fun) when is_function(fun, 0) do
    case Process.get(@key) do
      list when is_list(list) -> Process.put(@key, [fun | list]) && :ok
      nil -> fun.()
    end
  end

  @doc "Lets held-back effects happen, in the order they were held."
  def run(effects), do: Enum.each(effects, & &1.())
end
