defmodule Slipdock.GardenConfirmDocsTest do
  @moduledoc """
  Since #2638 a person deciding a garden proposal from Claude Code adds
  `--confirm`: the CLI says it is an agent there, and a bare `slipdock garden
  apply|dismiss <id>` is refused. Every place that tells a person how to decide
  one names it (#2661): the audit found the slipdock skill's findings line, the
  guide's findings paragraph and the garden listing's footer giving the bare
  command.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)

  # The command as a person is told to decide a proposal with, and the text
  # after it where `--confirm` belongs.
  @rule ~r/garden apply\|dismiss/
  @window 200

  defp files do
    [
      "README.md",
      "lib/slipdock_web/api_guide.ex",
      "cli/help.txt"
    ] ++
      Path.wildcard(Path.join(@root, "lib/slipdock_web/live/help_live/*.ex")) ++
      Path.wildcard(Path.join(@root, "cli/lib/**/*.ex")) ++
      Path.wildcard(Path.join(@root, "docs/**/*.md")) ++
      Path.wildcard(Path.join(@root, "priv/skills/**/*.md"))
  end

  defp relative(path), do: Path.relative_to(Path.expand(path, @root), @root)

  # Elixir comments in the CLI's source are notes for its readers, not
  # instructions a person sees.
  defp text(file) do
    text = File.read!(Path.join(@root, file))

    if String.starts_with?(file, "cli/lib/"),
      do: text |> String.split("\n") |> Enum.reject(&(&1 =~ ~r/^\s*#/)) |> Enum.join("\n"),
      else: text
  end

  defp hits(file, text) do
    for [{start, _}] <- Regex.scan(@rule, text, return: :index) do
      passage = binary_part(text, start, min(@window, byte_size(text) - start))
      {file, String.replace(passage, ~r/\s+/, " ")}
    end
  end

  defp hits, do: Enum.flat_map(Enum.map(files(), &relative/1), &hits(&1, text(&1)))

  defp missing(hits),
    do: for({file, passage} <- hits, not (passage =~ "--confirm"), do: {file, passage})

  test "each way of deciding a proposal names --confirm for Claude Code" do
    assert missing(hits()) == [],
           "a proposal decided with the bare command, refused under Claude Code: " <>
             inspect(missing(hits()))
  end

  test "the sweep reads the places the audit found" do
    files = hits() |> Enum.map(&elem(&1, 0)) |> MapSet.new()

    for file <- [
          "priv/skills/slipdock/SKILL.md",
          "lib/slipdock_web/api_guide.ex",
          "cli/lib/slipdock_cli/findings.ex",
          "cli/lib/slipdock_cli/garden.ex",
          "cli/help.txt"
        ],
        do: assert(file in files, file)
  end

  test "the garden listing's footer names --confirm beside apply and dismiss" do
    source = File.read!(Path.join(@root, "cli/lib/slipdock_cli/garden.ex"))
    [footer] = Regex.run(~r/" Apply: slipdock garden apply.{0,200}/s, source)
    assert footer =~ "--confirm"
  end

  test "the rule catches a bare command" do
    bare = "first the proposals (decide with garden apply|dismiss <id>), then the rest"
    assert [{"x", _}] = missing(hits("x", bare))
    assert missing(hits("x", "decide with garden apply|dismiss <id> --confirm")) == []
  end
end
