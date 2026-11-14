defmodule Slipdock.CLIHelp do
  @moduledoc """
  `cli/help.txt`, the CLI's usage text, as the docs tests that hold a
  `slipdock …` command to it read it (#2779, #3133). `slipdock help` prints
  it and the web app's command reference reads it; it is read as a file,
  since the CLI is a project of its own.
  """

  @root Path.expand("../..", __DIR__)

  @doc "The text of `cli/help.txt`."
  def read!, do: File.read!(Path.join(@root, "cli/help.txt"))

  @doc """
  The flags each command's help entry names: `%{["page", "section"] => set}`.
  An entry starts on a line at indent 0 or 2 with the command's name
  (`  page section <page> <path>`, `  finding <id> dismiss|promote|reopen`)
  and runs on over the more deeply indented lines under it. A command
  with several entries reads the flags of them all.
  """
  def help_flags(help) do
    help
    |> String.split("\n")
    |> Enum.chunk_while(
      nil,
      fn line, acc ->
        cond do
          entry?(line) and acc != nil -> {:cont, acc, {line, [line]}}
          entry?(line) -> {:cont, {line, [line]}}
          acc != nil and continuation?(line) -> {:cont, put_elem(acc, 1, [line | elem(acc, 1)])}
          acc != nil -> {:cont, acc, nil}
          true -> {:cont, nil}
        end
      end,
      fn
        nil -> {:cont, nil}
        acc -> {:cont, acc, nil}
      end
    )
    |> Enum.reduce(%{}, fn {head, lines}, map ->
      flags = lines |> Enum.join("\n") |> flags_in() |> MapSet.new()

      head
      |> entry_names()
      |> Enum.reduce(map, fn name, map ->
        Map.update(map, name, flags, &MapSet.union(&1, flags))
      end)
    end)
  end

  defp entry?(line), do: Regex.match?(~r/^ {0,2}[a-z]/, line)
  defp continuation?(line), do: Regex.match?(~r/^ {3,}\S/, line)

  # `finding <id> dismiss|promote|reopen  …` => [~w(finding dismiss), ~w(finding promote), …]:
  # its literal words up to the first flag, option group or the gap before
  # the description, the placeholders (`<id>`) left out. A usage of two
  # forms (`hook install lane-check | hook uninstall lane-check`) names each.
  defp entry_names(head) do
    [usage | _] = head |> String.trim() |> String.split(~r/\s{2,}/, parts: 2)

    usage
    |> String.split(~r/\s\|\s/)
    |> Enum.flat_map(&form_names/1)
    |> Enum.reject(&(&1 == []))
  end

  defp form_names(form) do
    form
    |> String.split()
    |> Enum.take_while(&(not String.starts_with?(&1, ["--", "[", "("])))
    |> Enum.filter(&Regex.match?(~r/^[a-z][a-z-]*(\|[a-z][a-z-]*)*$/, &1))
    |> Enum.map(&String.split(&1, "|"))
    |> Enum.reduce([[]], fn alts, acc -> for name <- acc, alt <- alts, do: name ++ [alt] end)
  end

  defp flags_in(text) do
    for [_, flag] <- Regex.scan(~r/(?:^|[\s\[(|`])--([a-z][a-z-]*)/, text), uniq: true, do: flag
  end

  @doc "The help entry a command's words name: the longest one they start with, or nil."
  def command(words, help) do
    help
    |> Map.keys()
    |> Enum.filter(&(&1 != [] and List.starts_with?(words, &1)))
    |> Enum.max_by(&length/1, fn -> nil end)
  end
end
