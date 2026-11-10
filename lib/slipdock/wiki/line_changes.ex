defmodule Slipdock.Wiki.LineChanges do
  @moduledoc """
  What a page revision changed, in the terms a person reads a history in:
  lines added and lines removed (#1698), worked out from the snapshots
  (`Slipdock.Wiki.Revision` keeps whole bodies, not diffs).

  Lines are compared in order, so a line moved counts as one removed and
  one added. Past `@exact_limit` lines between the two bodies the order is
  left out and only which lines are there is compared: a cheaper count, the
  same for every edit that doesn't only move lines about.
  """

  @exact_limit 4_000

  @typedoc "Lines added and removed, and whether the title changed with them."
  @type t :: %{added: non_neg_integer(), removed: non_neg_integer(), title?: boolean()}

  @doc """
  Lines added and removed going from `old` to `new` (bodies, `nil` for
  none), as `{added, removed}`.
  """
  def count(old, new) do
    a = lines(old)
    b = lines(new)

    if length(a) + length(b) > @exact_limit, do: rough(a, b), else: exact(a, b)
  end

  @doc """
  Each revision's changes, keyed by its id. `revisions` is newest first, as
  `Slipdock.Wiki.list_revisions/2` gives them; `before` is the revision
  before the oldest of them, or nil when that oldest is the page's first,
  whose every line counts as added.
  """
  def for_revisions(revisions, before \\ nil) do
    revisions
    |> Enum.reverse()
    |> Enum.map_reduce(before, fn revision, prev ->
      {added, removed} = count(prev && prev.body, revision.body)
      title? = prev != nil and prev.title != revision.title
      {{revision.id, %{added: added, removed: removed, title?: title?}}, revision}
    end)
    |> elem(0)
    |> Map.new()
  end

  @doc """
  The change as the history writes it: "+12 −3 lines", "+4 lines",
  "title only", or "no changes".
  """
  def label(%{added: 0, removed: 0, title?: true}), do: "title only"
  def label(%{added: 0, removed: 0}), do: "no changes"
  def label(%{added: a, removed: 0}), do: "+#{a} #{lines_word(a)}"
  def label(%{added: 0, removed: r}), do: "−#{r} #{lines_word(r)}"
  def label(%{added: a, removed: r}), do: "+#{a} −#{r} lines"

  @preview_limit 12

  # Past this many lines between the two bodies the preview leaves the
  # ordered diff out, as `count/2` does, and says so.
  @preview_exact_limit @exact_limit

  @doc """
  The lines a revision changed, for the history's preview of a row (#1745):
  `old` and `new` are bodies (`nil` for none), and the diff is
  `Slipdock.Wiki.diff/2`'s, the one the revision view's split view is
  built from. Blank lines are left out, since they change with every new
  paragraph and say nothing.

  Returns `%{lines: [{:del | :ins, text}], more: n, too_big?: false}`, at
  most `limit` lines with `more` counting the rest, or
  `%{lines: [], more: 0, too_big?: true}` for bodies too long to diff here.
  """
  def preview(old, new, limit \\ @preview_limit) do
    a = lines(old)
    b = lines(new)

    if length(a) + length(b) > @preview_exact_limit do
      %{lines: [], more: 0, too_big?: true}
    else
      changed =
        for {op, chunk} <- Slipdock.Wiki.diff(old, new),
            Enum.member?([:del, :ins], op),
            line <- chunk,
            String.trim(line) != "",
            do: {op, line}

      {shown, rest} = Enum.split(changed, limit)
      %{lines: shown, more: length(rest), too_big?: false}
    end
  end

  defp lines_word(1), do: "line"
  defp lines_word(_), do: "lines"

  # A body's lines, the newline at its end not making one more.
  defp lines(nil), do: []
  defp lines(""), do: []
  defp lines(body), do: body |> String.trim_trailing("\n") |> String.split("\n")

  defp exact(a, b) do
    Enum.reduce(List.myers_difference(a, b), {0, 0}, fn
      {:ins, l}, {add, del} -> {add + length(l), del}
      {:del, l}, {add, del} -> {add, del + length(l)}
      {:eq, _}, acc -> acc
    end)
  end

  defp rough(a, b) do
    fa = Enum.frequencies(a)
    fb = Enum.frequencies(b)
    added = Enum.reduce(fb, 0, fn {l, n}, acc -> acc + max(n - Map.get(fa, l, 0), 0) end)
    removed = Enum.reduce(fa, 0, fn {l, n}, acc -> acc + max(n - Map.get(fb, l, 0), 0) end)
    {added, removed}
  end
end
