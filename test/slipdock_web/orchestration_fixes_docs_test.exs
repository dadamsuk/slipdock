defmodule SlipdockWeb.OrchestrationFixesDocsTest do
  @moduledoc """
  Orchestration fixes (#1753). The snags passes used to work round are fixed
  on the server: a merge doesn't wait behind the pass (#1754), an epic's job
  may wait on its subcards (#1755), section writes keep headings and tables
  (#1756), a card is made with its bar and paths (#1757) and an epic can't be
  closed over open subcards (#1758). The agent guide, `docs/agents.md` and
  the packaged loop skill (`priv/skills/`, the one source, #2048) no longer
  tell an agent to work round them, and the loop skill files
  a card with its bar and paths in one write.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)

  defp flat(text), do: String.replace(text, ~r/\s+/, " ")

  defp loop_copies do
    [Path.join(@root, "priv/skills/slipdock-loop/SKILL.md")]
  end

  defp docs do
    [
      Path.join(@root, "lib/slipdock_web/api_guide.ex"),
      Path.join(@root, "docs/agents.md") | loop_copies()
    ]
  end

  # Each phrase is a workaround an earlier pass needed for one of the snags.
  @workarounds [
    ~r/open (the|its|a) wait on the epic/i,
    ~r/waits? (on a subcard )?go(es)? on the epic/i,
    ~r/start (the|your) body with (the|its) `?## ?heading/i,
    ~r/append_section (splits|breaks) tables/i,
    ~r/merges? (only )?(runs?|waits?) (only )?(after|until) the (epic's )?pass ends/i,
    ~r/then `?slipdock edit [^`]*--bar`?,? then `?--paths/i
  ]

  test "no workaround for a fixed snag is left in the guide, agents.md or the loop skill" do
    for path <- docs(), text = path |> File.read!() |> flat(), re <- @workarounds do
      refute text =~ re, "#{path} still describes a workaround: #{inspect(re)}"
    end
  end

  test "the loop skill files a card with its bar and paths in one write" do
    for path <- loop_copies() do
      loop = path |> File.read!() |> flat()

      for part <- [
            "**Its bar and paths go on in the same write**",
            ~s(`slipdock add <board> "<title>" --bar "…" --paths "a/**,b.md"`),
            "(`create_card` `bar` and `paths` over MCP)"
          ],
          do: assert(loop =~ part, "#{path}: #{part}")
    end
  end

  test "the fixes are what the docs now describe instead" do
    guide = Path.join(@root, "lib/slipdock_web/api_guide.ex") |> File.read!() |> flat()
    agents = Path.join(@root, "docs/agents.md") |> File.read!() |> flat()

    # Merges go to an idle runner first, not only the one that accepted (#1754).
    assert guide =~ "one idle now first"
    # The board refuses an epic over open subcards (#1758).
    assert guide =~ "open subcards"
    assert agents =~ "subcard"
  end
end
