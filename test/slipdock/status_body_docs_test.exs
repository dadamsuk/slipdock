defmodule Slipdock.StatusBodyDocsTest do
  @moduledoc """
  `slipdock status <id> <health>` takes a note of several lines as `--body -`
  (stdin), `--body TEXT` or `--file F` (#2700). The manual, the agents page
  and the packaged skills showed only the one-line form, so an agent with a
  note of several lines lost its line breaks or reached for MCP
  `status_update` instead (#2709). Every place in them that shows
  `slipdock status` names the three forms beside it, and a skill that sends a
  status note to MCP `status_update` names the CLI's `status --body -` there
  too.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)

  # How far after a mention of `slipdock status` the forms must appear.
  @window 400

  @forms ["--body -", "--body TEXT", "--file F"]

  defp files do
    ["docs/agents.md"] ++
      rel(Path.wildcard(Path.join(@root, "docs/manual/*.md"))) ++
      rel(Path.wildcard(Path.join(@root, "priv/skills/**/*.md")))
  end

  defp rel(paths), do: Enum.map(paths, &Path.relative_to(&1, @root))

  defp read(file), do: File.read!(Path.join(@root, file))

  # A mention of the command, in a sentence or as a line in a block
  # (`slipdock status W-31 …`), or in the manual's CLI list (`status <id>`).
  @mention ~r/slipdock status\b|`status <id>/

  defp missing_forms(text, offset) do
    window = binary_part(text, offset, min(@window, byte_size(text) - offset))
    Enum.reject(@forms, &String.contains?(window, &1))
  end

  defp gaps(file, pattern) do
    text = read(file)

    for [{start, _}] <- Regex.scan(pattern, text, return: :index),
        missing = missing_forms(text, start),
        missing != [] do
      line = text |> binary_part(0, start) |> String.split("\n") |> length()
      "#{file}:#{line} lacks #{Enum.join(missing, ", ")}"
    end
  end

  test "every mention of slipdock status in the manual, agents page and skills names the several-line forms" do
    assert Enum.flat_map(files(), &gaps(&1, @mention)) == []
  end

  test "each of the three places shows the several-line forms at all" do
    for place <- [
          "docs/manual/cli.md",
          "docs/manual/roadmap-features-in-the-api-and-cli.md",
          "docs/agents.md",
          "priv/skills/slipdock/SKILL.md",
          "priv/skills/slipdock-loop/SKILL.md",
          "priv/skills/slipdock-work/SKILL.md",
          "priv/skills/slipdock-wiki/SKILL.md",
          "priv/skills/slipdock-docs/SKILL.md"
        ] do
      text = read(place)
      assert text =~ @mention, "#{place} no longer mentions slipdock status"
      assert Enum.all?(@forms, &String.contains?(text, &1)), "#{place} lacks a several-line form"
    end
  end

  test "a skill sending a status note to MCP status_update names status --body - beside it" do
    skills = rel(Path.wildcard(Path.join(@root, "priv/skills/**/*.md")))

    gaps =
      for file <- skills,
          text = read(file),
          [{start, _}] <- Regex.scan(~r/`status_update`/, text, return: :index),
          from = max(start - @window, 0),
          not String.contains?(binary_part(text, from, start - from + 20), "status --body -") do
        line = text |> binary_part(0, start) |> String.split("\n") |> length()
        "#{file}:#{line}"
      end

    assert gaps == []
  end

  test "the check catches a one-line-only mention" do
    text = ~s[Post one (`slipdock status <id> at_risk "…"`) only for a risk.\n]
    [{start, _}] = Regex.run(@mention, text, return: :index)
    assert missing_forms(text, start) == @forms

    text = text <> "Several lines: `status --body -`, `--body TEXT` or `--file F`.\n"
    assert missing_forms(text, start) == []
  end
end
