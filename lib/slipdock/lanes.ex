defmodule Slipdock.Lanes do
  @moduledoc """
  Card paths (#1628): the globs a card's work touches, and how they match.

  A card can declare the paths its work will touch (`Card.paths`), as globs
  relative to the repository — `lib/slipdock/runners/**`, `test/*_test.exs`,
  `docs/{manual,agents}.md`. They scope the handbook rules and sections the
  card falls under (`Slipdock.Handbook`) and feed its profile's inference
  (`Slipdock.Profiles`). The lanes that once held overlapping work apart
  went in #3178: an overlap refuses, holds and advises nothing.

  Matching is on the globs alone: the server never sees a working tree. `*`
  and `?` stay inside one segment, `**` is any number of segments, `{a,b}`
  is either, and `[...]` is taken as any one character (so it errs towards
  overlapping). A path covers everything under it: `lib/foo` overlaps
  `lib/foo/bar.ex`. A card with no paths overlaps nothing.
  """

  @max_paths 50
  @max_length 200
  @max_expansions 64

  @doc "How many paths a card may declare, and how long each may be."
  def limits, do: %{paths: @max_paths, length: @max_length}

  ## Writing paths ------------------------------------------------------------

  @doc """
  `attrs` with a `paths` (or another `field` of globs)
  given as one string split into a list: one glob per line or comma (a comma
  inside `{…}` is part of the glob). A list, or no such key, is left alone.
  """
  def split_paths(attrs, field \\ :paths)

  def split_paths(%{} = attrs, field) do
    Enum.reduce([to_string(field), field], attrs, fn key, acc ->
      case acc do
        %{^key => value} when is_binary(value) -> Map.put(acc, key, split(value))
        _ -> acc
      end
    end)
  end

  def split_paths(attrs, _field), do: attrs

  @doc "One string of globs as a list: split on newlines, and on commas outside `{…}`."
  def split(text) when is_binary(text) do
    {parts, current, _depth} =
      text
      |> String.graphemes()
      |> Enum.reduce({[], "", 0}, fn
        "{", {parts, cur, d} -> {parts, cur <> "{", d + 1}
        "}", {parts, cur, d} -> {parts, cur <> "}", max(d - 1, 0)}
        "," = _c, {parts, cur, 0} -> {[cur | parts], "", 0}
        "\n", {parts, cur, d} -> {[cur | parts], "", d}
        c, {parts, cur, d} -> {parts, cur <> c, d}
      end)

    Enum.reverse([current | parts])
  end

  @doc """
  Tidies and checks a changeset's `paths`, or another field of globs, with
  the same rules.
  """
  def validate_paths(%Ecto.Changeset{} = changeset, field \\ :paths) do
    changeset
    |> Ecto.Changeset.update_change(field, &tidy/1)
    |> Ecto.Changeset.validate_change(field, fn ^field, paths ->
      case path_error(paths) do
        nil -> []
        message -> [{field, message}]
      end
    end)
  end

  @doc """
  The globs of `paths` that would pass `validate_paths/2`, tidied, at most
  as many as it allows: for a list read from somewhere else, such as an
  import, where one bad glob shouldn't lose the rest.
  """
  def keep_valid(paths) when is_list(paths) do
    paths
    |> Enum.filter(&is_binary/1)
    |> tidy()
    |> Enum.filter(&is_nil(path_error([&1])))
    |> Enum.take(@max_paths)
  end

  def keep_valid(_paths), do: []

  defp path_error(paths) do
    cond do
      length(paths) > @max_paths ->
        "lists at most #{@max_paths} paths"

      bad = Enum.find(paths, &(String.length(&1) > @max_length)) ->
        "has a path over #{@max_length} characters: #{String.slice(bad, 0, 40)}…"

      bad = Enum.find(paths, &absolute?/1) ->
        "are relative to the repository: #{bad} isn't"

      bad = Enum.find(paths, &Enum.member?(String.split(&1, "/"), "..")) ->
        "stay inside the repository: #{bad} has a .."

      bad = Enum.find(paths, &(not balanced?(&1))) ->
        "has unbalanced braces: #{bad}"

      true ->
        nil
    end
  end

  @doc "A list of globs, tidied: trimmed, `./` dropped, blanks and repeats left out."
  def tidy(nil), do: []

  def tidy(paths) when is_list(paths) do
    paths
    |> Enum.map(&(&1 |> to_string() |> String.trim() |> String.replace_prefix("./", "")))
    |> Enum.reject(&Enum.member?(["", "."], &1))
    |> Enum.uniq()
  end

  defp absolute?(path),
    do: String.starts_with?(path, ["/", "~", "\\"]) or Regex.match?(~r/\A[A-Za-z]:/, path)

  defp balanced?(path) do
    path
    |> String.graphemes()
    |> Enum.reduce_while(0, fn
      "{", d -> {:cont, d + 1}
      "}", 0 -> {:halt, -1}
      "}", d -> {:cont, d - 1}
      _, d -> {:cont, d}
    end)
    |> Kernel.==(0)
  end

  ## Overlap ------------------------------------------------------------------

  @doc "Whether any glob of `a` overlaps any glob of `b`."
  def overlap?(a, b) when is_list(a) and is_list(b) do
    Enum.any?(a, fn x -> Enum.any?(b, &glob_overlap?(x, &1)) end)
  end

  @doc """
  Whether some path could match both globs (each also covering everything
  under what it matches).
  """
  def glob_overlap?(a, b) do
    Enum.any?(expand(a), fn x ->
      Enum.any?(expand(b), fn y ->
        intersect?(segments(x), segments(y), "**", &segment_overlap?/2)
      end)
    end)
  end

  # `{a,b}` expanded, innermost first, to at most @max_expansions globs.
  defp expand(glob) do
    case Regex.run(~r/\{([^{}]*)\}/, glob, return: :index) do
      nil ->
        [glob]

      [{start, len}, {inner_start, inner_len}] ->
        prefix = binary_part(glob, 0, start)
        suffix = binary_part(glob, start + len, byte_size(glob) - start - len)
        options = glob |> binary_part(inner_start, inner_len) |> String.split(",")

        options
        |> Enum.flat_map(&expand(prefix <> &1 <> suffix))
        |> Enum.take(@max_expansions)
    end
  end

  # A glob's segments, with everything under it covered: `lib/foo` is
  # `lib/foo/**`. Empty segments (`a//b`, a trailing /) are dropped.
  defp segments(glob) do
    segs = glob |> String.split("/") |> Enum.reject(&Enum.member?(["", "."], &1))
    if List.last(segs) == "**", do: segs, else: segs ++ ["**"]
  end

  # Two segments overlap when some name matches both. A `**` inside a
  # segment is a `*`; a `[...]` class is any one character. Equal segments,
  # and two with no wildcard in them, are decided without the character
  # table (#1977: most pairs are plain names).
  defp segment_overlap?(same, same), do: true

  defp segment_overlap?(a, b) do
    if wild?(a) or wild?(b),
      do: intersect?(chars(a), chars(b), "*", &char_overlap?/2),
      else: false
  end

  defp wild?(segment), do: String.contains?(segment, ["*", "?", "["])

  defp chars(segment) do
    segment
    |> String.replace(~r/\*+/, "*")
    |> String.replace(~r/\[[^\]]*\]/, "?")
    |> String.graphemes()
  end

  defp char_overlap?(a, b), do: a == "?" or b == "?" or a == b

  # Whether two patterns over the same alphabet — `star` matching any run of
  # elements, `compat?` saying whether two single elements can be the same —
  # have a string in common. Dynamic programming from the ends.
  defp intersect?(xs, ys, star, compat?) do
    xs = List.to_tuple(xs)
    ys = List.to_tuple(ys)
    n = tuple_size(xs)
    m = tuple_size(ys)

    table =
      for i <- n..0//-1, j <- m..0//-1, reduce: %{} do
        dp ->
          x = i < n && elem(xs, i)
          y = j < m && elem(ys, j)

          value =
            cond do
              i == n and j == m -> true
              x == star -> dp[{i + 1, j}] or (j < m and dp[{i, j + 1}])
              y == star -> dp[{i, j + 1}] or (i < n and dp[{i + 1, j}])
              i == n or j == m -> false
              # The cell first: comparing two elements costs more (#1977).
              true -> dp[{i + 1, j + 1}] and compat?.(x, y)
            end

          Map.put(dp, {i, j}, value)
      end

    table[{0, 0}]
  end
end
