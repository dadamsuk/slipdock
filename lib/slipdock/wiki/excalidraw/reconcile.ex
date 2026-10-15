defmodule Slipdock.Wiki.Excalidraw.Reconcile do
  @moduledoc """
  Merges Excalidraw elements the way Excalidraw's own collaboration does
  (`reconcileElements`, packages/excalidraw/data/reconcile.ts in 0.18.1), so
  the server holding a live drawing (`Slipdock.Wiki.DrawingSession`) and the
  editors in the browser agree on every element without talking it over
  (W-1730).

  Each element carries a `version`, bumped on every edit, and a random
  `versionNonce`. For an element both sides have, the higher version wins;
  on a tie the lower nonce wins, and an equal nonce lets the incoming one
  through. Deleting is an edit like any other — `isDeleted: true` and a
  bumped version — so a deletion and a concurrent edit settle by the same
  rule, and the tombstone is kept.

  The merged list puts incoming ids first, then held ones not seen, and is
  then sorted by the fractional `index` (string order, then id), which is
  the drawing's z-order. Elements without an index (older scenes) keep their
  place after the indexed ones.
  """

  @type element :: %{optional(String.t()) => term}

  @doc """
  Merges `incoming` into `held`. Returns the merged list, and the incoming
  elements that won — what has to be passed on to everybody else.
  """
  @spec merge([element], [element]) :: {[element], [element]}
  def merge(held, incoming) when is_list(held) and is_list(incoming) do
    held_by_id = Map.new(held, &{&1["id"], &1})

    {merged, winners, seen} =
      Enum.reduce(incoming, {[], [], MapSet.new()}, fn element, {merged, winners, seen} ->
        id = element["id"]

        cond do
          not is_binary(id) or MapSet.member?(seen, id) ->
            {merged, winners, seen}

          keep_held?(held_by_id[id], element) ->
            {[held_by_id[id] | merged], winners, MapSet.put(seen, id)}

          true ->
            {[element | merged], [element | winners], MapSet.put(seen, id)}
        end
      end)

    rest = Enum.reject(held, &MapSet.member?(seen, &1["id"]))

    {order(Enum.reverse(merged, rest)), Enum.reverse(winners)}
  end

  @doc "Whether the element already held beats the one arriving."
  @spec keep_held?(element | nil, element) :: boolean
  def keep_held?(nil, _incoming), do: false

  def keep_held?(held, incoming) do
    {hv, iv} = {number(held["version"]), number(incoming["version"])}

    hv > iv or (hv == iv and number(held["versionNonce"]) < number(incoming["versionNonce"]))
  end

  defp number(n) when is_number(n), do: n
  defp number(_), do: 0

  @doc "Elements in z-order: by fractional `index`, then id; unindexed ones last, as they were."
  @spec order([element]) :: [element]
  def order(elements) do
    {indexed, loose} = Enum.split_with(elements, &is_binary(&1["index"]))
    Enum.sort_by(indexed, &{&1["index"], &1["id"]}) ++ loose
  end
end
