defmodule Slipdock.Wiki.Merge3 do
  @moduledoc """
  A line-level three-way merge: two texts that each started from `base`,
  put together when they changed different lines (#2772).

  It is what lets a handbook proposal (an `edit_section` step, which
  replaces its section whole) still apply after another proposal on the
  same section has: the section's `## Rules` are one rule per line, so two
  proposals that change different rules change different lines, and each
  is applied as its own lines rather than as the section it saw.

  Each side is compared with `base` as hunks: a run of base lines (perhaps
  none) and what that side puts in their place. A hunk both sides made
  alike is taken once. Two that cover any of the same base lines conflict.
  Two that only insert, at the same place, are both kept, `ours` first:
  two proposals that each add a rule at the end of the list.
  """

  @type lines :: [String.t()]

  @doc """
  Merges `ours` and `theirs`, both lists of lines descended from `base`.
  `{:ok, lines}`, or `{:conflict, base_lines}` with the base lines both
  sides changed.
  """
  @spec merge(lines, lines, lines) :: {:ok, lines} | {:conflict, lines}
  def merge(base, ours, theirs) do
    mine = hunks(base, ours, 0)
    other = Enum.reject(hunks(base, theirs, 1), &same_as_any?(&1, mine))

    case Enum.find(for(a <- mine, b <- other, overlap?(a, b), do: {a, b}), & &1) do
      nil ->
        {:ok, (mine ++ other) |> Enum.sort_by(&{&1.from, &1.to, &1.side}) |> stitch(base)}

      {a, b} ->
        from = min(a.from, b.from)
        to = max(max(a.to, b.to), from + 1)
        {:conflict, Enum.slice(base, from, to - from)}
    end
  end

  @doc "`merge/3` on texts rather than lines; trailing blank lines are ignored."
  @spec merge_text(String.t(), String.t(), String.t()) :: {:ok, String.t()} | {:conflict, lines}
  def merge_text(base, ours, theirs) do
    case merge(lines(base), lines(ours), lines(theirs)) do
      {:ok, merged} -> {:ok, Enum.join(merged, "\n")}
      conflict -> conflict
    end
  end

  defp lines(text), do: text |> String.trim_trailing() |> String.split("\n")

  # The changes from base to other, as %{from, to, lines, side}: base lines
  # from..to-1 become lines.
  defp hunks(base, other, side) do
    {done, _at, open} =
      base
      |> List.myers_difference(other)
      |> Enum.reduce({[], 0, nil}, fn
        {:eq, eq}, {done, at, open} ->
          {close(done, open), at + length(eq), nil}

        {:del, del}, {done, at, open} ->
          hunk = open || %{from: at, to: at, lines: [], side: side}
          {done, at + length(del), %{hunk | to: hunk.to + length(del)}}

        {:ins, ins}, {done, at, open} ->
          hunk = open || %{from: at, to: at, lines: [], side: side}
          {done, at, %{hunk | lines: hunk.lines ++ ins}}
      end)

    done |> close(open) |> Enum.reverse()
  end

  defp close(done, nil), do: done
  defp close(done, hunk), do: [hunk | done]

  defp same_as_any?(hunk, hunks),
    do: Enum.any?(hunks, &(&1.from == hunk.from and &1.to == hunk.to and &1.lines == hunk.lines))

  # Two hunks clash when they cover a base line in common, or when one
  # inserts strictly inside the lines the other replaces. Two insertions at
  # one place, or a change that ends where the other starts, don't.
  defp overlap?(a, b), do: a.from < b.to and b.from < a.to

  defp stitch(hunks, base) do
    {out, at} =
      Enum.reduce(hunks, {[], 0}, fn hunk, {out, at} ->
        {[hunk.lines, Enum.slice(base, at, hunk.from - at) | out], hunk.to}
      end)

    [Enum.drop(base, at) | out] |> Enum.reverse() |> Enum.concat()
  end
end
