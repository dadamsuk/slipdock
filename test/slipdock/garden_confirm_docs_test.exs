defmodule Slipdock.GardenConfirmDocsTest do
  @moduledoc """
  Since #2668 a garden proposal is decided on the board's Tidy-up page, signed
  in, and nowhere else: REST, the CLI and MCP are refused with the page's link,
  whatever `--confirm` or `confirm` they send. So no place tells a person to
  decide one with `slipdock garden apply|dismiss|undo <id> --confirm` any more
  (#2688), and the places #2661's audit found (the slipdock skill's findings
  line, the guide's findings paragraph, the garden listing's footer and the
  findings hint) point at the Tidy-up page instead.
  """
  use ExUnit.Case, async: true

  import Slipdock.DocsFacts, only: [assert_states: 2]

  @root Path.expand("../..", __DIR__)

  # `--confirm` near a garden decision: the route #2668 closed.
  @rule ~r/garden (apply|dismiss|undo)[^\n]{0,80}--confirm/

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
    text = Slipdock.DocsText.read!(Path.join(@root, file))

    if String.starts_with?(file, "cli/lib/"),
      do: text |> String.split("\n") |> Enum.reject(&(&1 =~ ~r/^\s*#/)) |> Enum.join("\n"),
      else: text
  end

  defp flat(text), do: String.replace(text, ~r/\s+/, " ")

  defp confirms(file, text), do: for(_ <- Regex.scan(@rule, flat(text)), do: file)

  defp confirms, do: Enum.flat_map(Enum.map(files(), &relative/1), &confirms(&1, text(&1)))

  test "no place decides a proposal with --confirm" do
    assert confirms() == [], "a proposal decided with --confirm, refused since #2668"
  end

  test "the places the audit found point at the Tidy-up page" do
    for file <- [
          "priv/skills/slipdock/SKILL.md",
          "lib/slipdock_web/api_guide.ex",
          "cli/lib/slipdock_cli/findings.ex",
          "cli/lib/slipdock_cli/garden.ex",
          "cli/help.txt"
        ],
        do: assert(flat(text(file)) =~ "the board's Tidy-up page", file)
  end

  test "the garden listing's footer and the findings hint name the Tidy-up page" do
    garden = File.read!(Path.join(@root, "cli/lib/slipdock_cli/garden.ex"))
    [footer] = Regex.run(~r/" Apply: slipdock garden apply.{0,200}/s, garden)
    assert footer =~ "proposals_footer"

    assert_states(
      garden,
      ~s|" (a proposal: on the board's Tidy-up page, \#{tidy_url(s["board_id"])})"|
    )

    assert_states(garden, ~s|"      a person's to decide, on the board's Tidy-up page: "|)
    refute garden =~ "[--confirm]"

    findings = File.read!(Path.join(@root, "cli/lib/slipdock_cli/findings.ex"))
    assert_states(findings, ~s|"  Decide each on the board's Tidy-up page: "|)
    refute findings =~ "add --confirm"
  end

  test "the rule catches --confirm beside a decision, and only there" do
    assert confirms("x", "decide with garden apply|dismiss <id> --confirm") == ["x"]
    assert confirms("x", "slipdock garden undo 41\n --confirm") == ["x"]
    assert confirms("x", "a proposal is decided on the board's Tidy-up page") == []
    assert confirms("x", "`delete_card` needs `confirm: true`") == []
  end
end
