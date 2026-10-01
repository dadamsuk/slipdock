defmodule Slipdock.Wiki.Section do
  @moduledoc """
  Addressing part of a page by its heading: `"Deploy/Rollback"` is the
  `## Rollback` under the `# Deploy`.

  This is the mitigation for the conflict a whole-body write invites. Two
  writers touching different sections do not collide, and an agent appending
  a dated line under `## Log` should never have to send the whole document
  back — which is both a waste and the moment somebody's paragraph goes
  missing.

  Everything here is a pure function of the body text. Headings are ATX only
  (`## Like this`), matched case-insensitively on their text; fenced code is
  tracked so a `#` inside a code block is never mistaken for one.

  A section runs from its heading to the next heading at the same level or
  higher, so replacing `## Rollback` takes its `### …` subsections with it —
  which is what anyone editing "the rollback section" means.
  """

  @type path :: String.t()

  @doc """
  Every heading in the body, as `%{path:, title:, level:, line:}` — the
  table of contents, and what an error message lists when a path misses.
  """
  @spec headings(String.t() | nil) :: [map]
  def headings(nil), do: []

  def headings(body) do
    body
    |> lines()
    |> scan()
    |> Enum.reduce({[], []}, fn {level, title, line}, {found, stack} ->
      stack = Enum.take_while(stack, fn {l, _} -> l < level end) ++ [{level, title}]
      path = Enum.map_join(stack, "/", fn {_, t} -> t end)
      {[%{path: path, title: title, level: level, line: line} | found], stack}
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  @doc """
  The text of one section, heading included.

  Returns `{:ok, text}`, or `{:error, :not_found}` when nothing answers to
  that path.
  """
  @spec read(String.t() | nil, path) :: {:ok, String.t()} | {:error, :not_found}
  def read(body, path) do
    with {:ok, {from, to}} <- span(body, path) do
      {:ok, body |> lines() |> Enum.slice(from..(to - 1)//1) |> Enum.join("\n")}
    end
  end

  @doc """
  Replaces a section's text. The replacement is used as given, so it should
  carry its own heading — read it first if you mean to keep the old one.
  """
  @spec replace(String.t() | nil, path, String.t()) :: {:ok, String.t()} | {:error, :not_found}
  def replace(body, path, text) do
    with {:ok, {from, to}} <- span(body, path) do
      all = lines(body)
      kept_before = Enum.slice(all, 0, from)
      kept_after = Enum.slice(all, to..-1//1)
      # Keep one blank line between the new text and whatever follows, so a
      # replacement that forgot its trailing newline cannot weld itself to the
      # next heading.
      replacement = text |> String.trim_trailing() |> lines()
      spacer = if kept_after == [], do: [], else: [""]
      {:ok, Enum.join(kept_before ++ replacement ++ spacer ++ kept_after, "\n")}
    end
  end

  @doc """
  Adds `text` to the end of a section, before whatever follows it.

  This is the write that can never conflict, and the one an agent should
  reach for: appending a dated note under `## Log` touches nothing anyone
  else wrote.
  """
  @spec append(String.t() | nil, path, String.t()) :: {:ok, String.t()} | {:error, :not_found}
  def append(body, path, text) do
    with {:ok, {_from, to}} <- span(body, path) do
      all = lines(body)
      {before, rest} = Enum.split(all, to)

      before =
        before |> Enum.reverse() |> Enum.drop_while(&(String.trim(&1) == "")) |> Enum.reverse()

      added = text |> String.trim_trailing() |> lines()

      # A bullet added to a list of bullets is part of that list; anything
      # else is a new paragraph. Getting this wrong turns one tight list into
      # two loose ones, which is visible and annoying.
      separator = if continues_list?(List.last(before), List.first(added)), do: [], else: [""]

      {:ok,
       (before ++ separator ++ added ++ [""] ++ rest)
       |> Enum.join("\n")
       |> String.trim_trailing()
       |> Kernel.<>("\n")}
    end
  end

  defp continues_list?(last, first) when is_binary(last) and is_binary(first),
    do: list_item?(last) and list_item?(first)

  defp continues_list?(_last, _first), do: false

  defp list_item?(line), do: Regex.match?(~r/^\s*(?:[-*+]\s|\d+[.)]\s)/, line)

  @doc "Adds `text` to the end of the whole page."
  @spec append(String.t() | nil, String.t()) :: String.t()
  def append(body, text) do
    case String.trim_trailing(body || "") do
      "" -> String.trim_trailing(text) <> "\n"
      kept -> kept <> "\n\n" <> String.trim_trailing(text) <> "\n"
    end
  end

  ## Internals ---------------------------------------------------------------

  # The line range `[from, to)` a section occupies, heading included.
  defp span(body, path) do
    all = lines(body)
    wanted = normalize(path)

    headings(body)
    |> Enum.find(&(normalize(&1.path) == wanted or normalize(&1.title) == wanted))
    |> case do
      nil ->
        {:error, :not_found}

      %{line: line, level: level} ->
        following =
          all
          |> scan()
          |> Enum.find(fn {l, _title, at} -> at > line and l <= level end)

        {:ok, {line, (following && elem(following, 2)) || length(all)}}
    end
  end

  # `{level, title, line index}` for every ATX heading outside fenced code.
  defp scan(lines) do
    lines
    |> Enum.with_index()
    |> Enum.reduce({[], nil}, fn {line, index}, {found, fence} ->
      trimmed = String.trim_leading(line)

      cond do
        fence && fence_end?(trimmed, fence) ->
          {found, nil}

        fence ->
          {found, fence}

        opening = fence_start(trimmed) ->
          {found, opening}

        match = Regex.run(~r/^(\#{1,6})\s+(.+?)\s*\#*\s*$/, trimmed) ->
          [_, hashes, title] = match
          {[{String.length(hashes), title, index} | found], nil}

        true ->
          {found, nil}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp fence_start(line) do
    case Regex.run(~r/^(`{3,}|~{3,})/, line) do
      [_, fence] -> fence
      _ -> nil
    end
  end

  defp fence_end?(line, fence) do
    String.starts_with?(line, String.slice(fence, 0, 1)) and
      String.length(fence_start(line) || "") >= String.length(fence)
  end

  defp lines(nil), do: []
  defp lines(text), do: String.split(text, "\n")

  # Paths are matched on their words, so "Deploy / Rollback", "deploy/rollback"
  # and "Deploy/Rollback" are the same address.
  defp normalize(path) do
    path
    |> to_string()
    |> String.split("/")
    |> Enum.map_join("/", &(&1 |> String.trim() |> String.downcase()))
  end
end
