defmodule SlipdockWeb.ReasonShapeDocsTest do
  @moduledoc """
  What agents write onto a card has a shape (#2692): the skills, the CLI's
  help, docs/agents.md and the MCP tools' fields ask for lines, not a
  paragraph, and their examples of a reason, evidence and a handoff are in
  that shape, sent on stdin, rather than prose in one shell argument.
  """
  use SlipdockWeb.ConnCase, async: true

  @root Path.expand("../..", __DIR__)

  defp read(path), do: @root |> Path.join(path) |> File.read!()
  defp flat(text), do: String.replace(text, ~r/\s+/u, " ")

  test "the loop skill asks every text it writes for the shape, with examples in it" do
    skill = read("priv/skills/slipdock-loop/SKILL.md")
    flat = flat(skill)

    assert skill =~ "### What else you write onto a card"

    assert flat =~
             "a verdict's `--reason`, the `--evidence`, a `job-progress` note, a handoff's body, a status"

    assert flat =~ "**a first line that stands on its own**"
    assert flat =~ "**one short line per point**, never one paragraph"
    assert flat =~ "**the parts in their fields**, not repeated in the text"

    # The verify example is the shape, on stdin.
    assert skill =~
             "--reason - <<'EOF'\n  bar 2: the export drops archived cards\n\n  - `Export.run/1`"

    # The handoff example is a line each, on stdin.
    assert skill =~ ~s(--body - <<'EOF'\n- State: …\n- Gotchas: …)

    refute skill =~ ~s(--reason "what you checked")
    refute skill =~ ~s(reject --reason "<the check>: <what falls short, specifically>")
    refute skill =~ ~s(--body "State: …\nGotchas)
    refute skill =~ ~s(--evidence "Rejected\n  at abc1234)
  end

  test "the work and slipdock skills say the same, and their examples read stdin" do
    work = "priv/skills/slipdock-work/SKILL.md" |> read() |> flat()
    assert work =~ "**The same shape for all you write onto a card**"
    assert work =~ "A first line that stands on its own"
    assert work =~ "--evidence -`, the text on stdin"
    assert work =~ "--reason -` (the reason shaped as a comment is, its parts in `--check`)"
    assert work =~ "job-progress <job> --message -` with the note on stdin"
    refute work =~ ~s(--body "State: … Gotchas:)

    cli = read("priv/skills/slipdock/SKILL.md")
    assert cli =~ "--suite passed:38:0 --evidence - <<'EOF'"
    assert cli =~ ~s(--check bar:2=fail:"why" --reason - <<'EOF')
    refute cli =~ ~s(reject --reason "bar 2: …")
  end

  test "no skill, help or agents-page example passes evidence as one shell argument" do
    for path <-
          Path.wildcard(Path.join(@root, "priv/skills/*/SKILL.md")) ++
            [Path.join(@root, "docs/agents.md"), Path.join(@root, "cli/help.txt")],
        text = File.read!(path),
        flat = flat(text) do
      refute flat =~ ~r/--evidence ["<]/u,
             "#{Path.relative_to(path, @root)} shows --evidence \"…\""
    end

    loop = "priv/skills/slipdock-loop/SKILL.md" |> read() |> flat()
    # An epic's, a no-code card's and a spike's completion, each on stdin.
    assert loop =~ "done <id> --evidence - <<'EOF'`, then the evidence as lines"
    assert loop =~ ~s(--no-code "<why>" --evidence - <<'EOF'`, then what you did as lines)
    assert loop =~ ~s(prototype on card-<id>" --evidence - <<'EOF'`, then the evidence as lines)

    work = "priv/skills/slipdock-work/SKILL.md" |> read() |> flat()
    assert work =~ "`slipdock done <id> --evidence -` (the evidence on stdin, as lines"
    assert work =~ ~s(--no-code "<why>" --evidence -` \(what you did, on stdin as lines)

    cli = read("priv/skills/slipdock/SKILL.md")
    assert cli =~ ~s(slipdock done <id> --no-code "<why>" --evidence - <<'EOF')

    agents = "docs/agents.md" |> read() |> flat()
    assert agents =~ "`slipdock done --evidence -` (the evidence on stdin, as lines"
    assert agents =~ ~s(--no-code "<why>" --evidence -` \(what was done, on stdin as lines)
  end

  test "the CLI's help asks for the shape on verify, done, comment, job-progress and handoff" do
    help = read("cli/help.txt")
    flat = flat(help)

    assert flat =~ "The reason is lines, not a paragraph: a first line that stands alone"
    assert flat =~ "Write the evidence as lines, not a paragraph"
    assert flat =~ "Write lines, not a paragraph: a bold first line that stands alone"
    assert flat =~ "so a note keeps its lines"
    assert flat =~ "the body is lines, not a paragraph: one short line each for State"
    assert flat =~ "for a note of several lines, the MCP status_update body"
    # Its examples are the shape.
    assert help =~ "bar 2 fails: the export drops archived cards\n\n"
    assert help =~ "Built and tested; CI green.\n\n"
  end

  test "docs/agents.md says it, with an example, and the rework title is the first line" do
    agents = read("docs/agents.md")
    flat = flat(agents)

    assert flat =~ "**What an agent writes onto a card has a shape, not a paragraph**"

    assert flat =~
             "the parts go in their fields (`--check`, `--evidence-commit`, `--tests`, `--suite`, `--pr`)"

    assert agents =~
             "--reason - <<'EOF'\nbar 2: the export drops archived cards\n\n- `Export.run/1`"

    assert flat =~ "titled `Audit of #<id>: <the reason's first line>`"
    assert flat =~ "An agent's reason that arrives as a bare `-`"
    assert flat =~ "is refused, as dashed evidence is"

    assert flat(read("cli/help.txt")) =~ "an agent's reason that arrives as a bare - is refused"
  end

  test "the MCP tools ask for the shape in the fields an agent writes onto a card", %{conn: conn} do
    tools =
      conn
      |> put_req_header("content-type", "application/json")
      |> post("/mcp", Jason.encode!(%{jsonrpc: "2.0", id: 1, method: "tools/list"}))
      |> json_response(200)
      |> get_in(["result", "tools"])

    field = fn tool, name ->
      Enum.find(tools, &(&1["name"] == tool))["inputSchema"]["properties"][name]["description"]
    end

    shape = SlipdockWeb.MCP.Tool.shape()
    assert shape =~ "Lines, not a paragraph: a first line that stands alone"

    for {tool, name} <- [
          {"verify_card", "reason"},
          {"complete_card", "evidence"},
          {"complete_card", "comment"},
          {"job_progress", "note"},
          {"status_update", "body"}
        ],
        do: assert(field.(tool, name) =~ shape, "#{tool}.#{name}")

    assert field.("verify_card", "reason") =~ "the parts go in checks, not here"
    assert field.("complete_card", "evidence") =~ "go in their own fields, not here"
    assert field.("leave_handoff", "body") =~ "One short line each (`- …`), not a paragraph"
  end

  test "the leave-handoff prompt asks for a line each", %{conn: conn, user: user} do
    board = Slipdock.Fixtures.board_fixture(%{"name" => "Handoffs"}, owner: user)
    card = Slipdock.Fixtures.card_fixture(hd(board.columns), %{"title" => "Hand it on"})

    text =
      conn
      |> put_req_header("content-type", "application/json")
      |> post(
        "/mcp",
        Jason.encode!(%{
          jsonrpc: "2.0",
          id: 1,
          method: "prompts/get",
          params: %{name: "leave-handoff", arguments: %{card: "#{card.id}"}}
        })
      )
      |> json_response(200)
      |> get_in(["result", "messages", Access.at(0), "content", "text"])
      |> flat()

    assert text =~ "one short line each (`- State: …`), not a paragraph"
  end
end
