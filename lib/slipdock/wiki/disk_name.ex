defmodule Slipdock.Wiki.DiskName do
  @moduledoc """
  The name a thing has on disk (W-2201 §Names): derived, never stored, and
  the only place that decides it, so an export, a sync and a listing agree.

  `clean/1` changes characters and never shortens: matching a `[[link]]`
  uses it, so two pages sharing a long prefix never answer to one link.
  `disk_name/3` is `clean/1` bound to 60 characters, for a path. `assign/2`
  names a directory's children, telling clashes apart with a number.
  """

  @max 60
  @reserved ~w(CON PRN AUX NUL) ++
              Enum.map(1..9, &"COM#{&1}") ++ Enum.map(1..9, &"LPT#{&1}")

  @doc "The longest a folder or a file's stem may be."
  def max, do: @max

  @doc """
  `name` with only what every filesystem can hold in it, any length. `""`
  when nothing is left.
  """
  def clean(name) do
    name
    |> to_string()
    |> String.replace(~r/[[:cntrl:]]/u, "")
    |> String.replace(~r/[\/\\:*?"<>|]+/u, "-")
    |> String.replace(~r/[#^\[\]]+/u, "")
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
    |> String.replace(~r/^[. ]+/u, "")
    |> tidy_end()
    |> unreserved()
  end

  @doc """
  `name` cleaned and at most `max` characters, cut at a word when that keeps
  at least half and ending in `…`. `fallback` when nothing is left.
  """
  def disk_name(name, fallback \\ "Untitled", max \\ @max) do
    case name |> clean() |> shorten(max) do
      "" -> fallback
      name -> name
    end
  end

  @doc "`name` at most `max` characters, as `disk_name/3` cuts it. Already clean."
  def shorten(name, max) do
    if String.length(name) <= max do
      name
    else
      cut = String.slice(name, 0, max - 1)
      # The cut landing exactly between two words keeps the last of them.
      head = if String.at(name, max - 1) == " ", do: cut, else: word_cut(cut, div(max, 2))
      String.replace(head, ~r/[ \-,.;:_]+$/u, "") <> "…"
    end
  end

  defp word_cut(cut, keep) do
    case cut |> String.graphemes() |> Enum.with_index() |> last_space() do
      nil -> cut
      at when at >= keep -> String.slice(cut, 0, at)
      _ -> cut
    end
  end

  defp last_space(indexed) do
    indexed
    |> Enum.filter(fn {char, _at} -> char == " " end)
    |> List.last()
    |> case do
      nil -> nil
      {_char, at} -> at
    end
  end

  @doc """
  Names a directory's children. `children` are `{key, name}` or `{key, name,
  ext}` (`ext` kept whole and outside the bound), oldest first: `name` is
  made a disk name, and a clash, compared case aside as half the machines a
  vault reaches do, takes ` (2)`, ` (3)`… inside the bound, so the oldest
  keeps the plain name and a newer sibling renumbers nothing. A `name` of
  `{name, fallback}` says what an empty one becomes.

  `taken` holds names already used in the directory. Answers `%{key => name}`,
  `ext` included.
  """
  def assign(children, taken \\ []) do
    taken = MapSet.new(taken, &String.downcase/1)

    children
    |> Enum.map_reduce(taken, fn child, taken ->
      {key, source, ext} = shape(child)
      {name, fallback} = source_of(source)
      base = name |> clean() |> then(&if(&1 == "", do: fallback, else: &1))

      chosen =
        Stream.iterate(1, &(&1 + 1))
        |> Stream.map(&(numbered(base, &1) <> ext))
        |> Enum.find(&(not MapSet.member?(taken, String.downcase(&1))))

      {{key, chosen}, MapSet.put(taken, String.downcase(chosen))}
    end)
    |> elem(0)
    |> Map.new()
  end

  @doc "A clean `base` as the `n`th of its name: the suffix fits inside the bound."
  def numbered(base, 1), do: shorten(base, @max) |> tidy_end()

  def numbered(base, n) do
    suffix = " (#{n})"
    (base |> shorten(@max - String.length(suffix)) |> tidy_end()) <> suffix
  end

  defp shape({key, name}), do: {key, name, ""}
  defp shape({_key, _name, _ext} = child), do: child

  defp source_of({name, fallback}), do: {name, fallback}
  defp source_of(name), do: {name, "Untitled"}

  defp tidy_end(name), do: String.replace(name, ~r/[. ]+$/u, "")

  defp unreserved(name) do
    if Enum.member?(@reserved, String.upcase(name)), do: name <> "_", else: name
  end
end
