defmodule Slipdock.FrontMatterGen do
  @moduledoc """
  Random front matter, for the property tests of `Slipdock.Wiki.FrontMatter`:
  the shapes Obsidian, hand editing and other tools actually leave behind —
  comments, quoting both ways, flow and block lists, nested maps, empty
  values, blank lines, CRLF — and a body after it.

  Seeded, so a failure names the seed that reproduces it.
  """

  @unknown ~w(created cssclasses publish rating source author kind due mood project area)

  @doc "`{file, %{yaml:, keys:, nl:}}` from a seed. `owned` adds Slipdock's own keys at random."
  def file(seed, opts \\ []) do
    :rand.seed(:exsss, {seed, seed * 7 + 1, seed * 13 + 2})
    nl = pick(["\n", "\n", "\r\n"])
    keys = Enum.take_random(@unknown ++ owned(opts), :rand.uniform(6))
    blocks = Enum.map(keys, &block(&1, nl)) |> sprinkle(nl)
    yaml = blocks |> Enum.join() |> String.trim_trailing(nl)
    gap = pick(["", nl, nl <> nl])
    body = pick(["Body", "# Heading#{nl}#{nl}Text", "", "Some *text* and [[a link]]."])
    {"---" <> nl <> yaml <> nl <> "---" <> nl <> gap <> body, %{yaml: yaml, keys: keys, nl: nl}}
  end

  defp owned(opts), do: if(opts[:owned], do: ~w(title summary status template), else: [])

  defp block("title", nl),
    do: "title: " <> pick(["Plain title", "\"Quoted: title\"", "'It''s'"]) <> nl

  defp block("summary", nl), do: "summary: " <> pick(["short", "\"a: b\""]) <> nl

  defp block("status", nl),
    do: "status: " <> pick(["draft", "published", "reading", "\"draft\""]) <> nl

  defp block("template", nl), do: "template: " <> pick(["true", "false", "yes"]) <> nl

  defp block(key, nl) do
    case :rand.uniform(7) do
      1 -> "#{key}: #{word()}#{nl}"
      2 -> "#{key}: \"#{word()} #{word()}: #{word()}\" # a comment#{nl}"
      3 -> "#{key}: '#{word()}''s'#{nl}"
      4 -> "#{key}: [#{word()}, \"#{word()} #{word()}\"]#{nl}"
      5 -> "#{key}:#{nl}  - #{word()}#{nl}  - \"#{word()}\"#{nl}"
      6 -> "#{key}:#{nl}  sub: #{word()}#{nl}  other: 2#{nl}"
      7 -> "#{key}:#{nl}"
    end
  end

  # Comment and blank lines, before the first key and between the others.
  defp sprinkle(blocks, nl) do
    Enum.flat_map(blocks, fn block ->
      case :rand.uniform(5) do
        1 -> ["# note about it#{nl}", block]
        2 -> [nl, block]
        _ -> [block]
      end
    end)
  end

  defp word, do: pick(~w(alpha beta gamma délta ε 2026-10-12 x_y café))
  defp pick(list), do: Enum.random(list)
end
