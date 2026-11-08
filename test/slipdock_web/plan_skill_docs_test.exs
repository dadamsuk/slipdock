defmodule SlipdockWeb.PlanSkillDocsTest do
  @moduledoc """
  The `slipdock-plan` skill (#2043): the one thing a user installs to plan
  on a board. Both copies are the same, its front matter keeps the caps the
  other skills keep, it covers the five steps, its stage texts stay short
  enough to read beside a Playbook page, and its baseline is the Handbook
  Tool's own seed, so a board with no handbook plans as one with an
  untouched handbook does. The docs name it and say when it runs.
  """
  # The help page and the blueprint's pages are rendered, so this needs the database.
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Slipdock.Handbook

  @root Path.expand("../..", __DIR__)
  @priv Path.join(@root, "priv/skills/slipdock-plan/SKILL.md")

  defp flat(text), do: text |> String.replace(~r/\s+/, " ") |> String.trim()
  defp skill, do: File.read!(@priv)

  # The text under a heading, up to the next heading of that level or above.
  defp section(text, heading) do
    n = heading |> String.split(" ") |> hd() |> String.length()
    [_, rest] = String.split(text, "\n" <> heading <> "\n", parts: 2)
    ~r/\n\#{1,#{n}} /m |> Regex.split(rest, parts: 2) |> hd()
  end

  # The `- **Size**: …` bullets of a sizing list, flattened.
  defp sizes(text) do
    ~r/^- (\*\*(?:System|Feature|Card)\*\*:.+?)(?=^- |^\s*$|\z)/ms
    |> Regex.scan(text)
    |> Enum.map(fn [_, item] -> flat(item) end)
  end

  defp seed_playbook do
    Enum.find(Handbook.blueprint()["pages"], &(&1["title"] == "Playbook"))["body"]
  end

  test "its front matter is inside the caps" do
    assert [_, front, _] = String.split(skill(), "---\n", parts: 3)
    assert front =~ ~r/^name: slipdock-plan$/m
    [_, description] = Regex.run(~r/^description: (.+)$/m, front)
    # Claude's cap on a skill's description is 1,024 characters.
    assert String.length(description) <= 1024
    assert description =~ ~s{"plan this"}
    assert description =~ ~s{Not for "add a card…"}

    assert %{name: "slipdock-plan"} = Slipdock.Skills.get("slipdock-plan")
  end

  test "it covers the five steps" do
    text = skill()

    for heading <- [
          "## 1. Find the handbook",
          "## 2. Size the ask",
          "## 3. Run the stages",
          "## 4. Write where the Playbook says",
          "## 5. The person's defaults"
        ],
        do: assert(text =~ "\n" <> heading <> "\n", heading)

    flat = flat(text)
    # No handbook: offered, installed only on a yes, else the baseline.
    assert flat =~ "**No handbook:** say so, and offer to install one"
    assert flat =~ "`install_tool` with `tool: \"handbook\"`"
    assert flat =~ "Install it only when the person says yes"
    # The card-sized stop.
    assert flat =~ "**Card-sized:** make the card as the Playbook's `## Card shape` says"
    assert flat =~ "and **stop**"
    # A named skill: enabled on the board, else installed, else the built-in
    # text, in that order, saying which (#2063).
    assert flat =~ "When the section names one (`skill: <name>`), take the first of these"
    assert flat =~ "and say which you used"
    step = section(text, "## 3. Run the stages") |> flat()

    enabled =
      :binary.match(step, "1. **Enabled on the board.** `slipdock skills board <board> <name>`")

    installed = :binary.match(step, "2. **Installed here.**")
    neither = :binary.match(step, "3. **Neither:** use this file's text for the stage")
    assert [enabled, installed, neither] |> Enum.all?(&(&1 != :nomatch))
    assert elem(enabled, 0) < elem(installed, 0) and elem(installed, 0) < elem(neither, 0)
    assert step =~ "MCP: `get_guide` with `board`"
    assert step =~ "a `changed` status means upstream moved on and the pinned text is still"
    # The Decision page's shape.
    assert flat =~ "titled `Decision: <what was chosen>`, with four parts: **Context**"
    assert flat =~ "**The choice**, **Alternatives** (each, and why not), **Where decided**"
    # Principles are a person's call; the spec and the cards land where the Playbook says.
    assert flat =~ "When the person agreed it in this conversation, append both"
    assert flat =~ "`slipdock garden propose <board> -`"
    assert flat =~ "--card <epic>"
    assert flat =~ "A default is never imposed."
  end

  test "its section writes are ones the CLI takes (#2039 trial)" do
    text = flat(skill())
    help = File.read!(Path.join(@root, "cli/help.txt"))

    # `page section … --append` takes the text (or `-` for stdin), not a further `--body`.
    assert help =~ "page section <page> <path> --append TEXT"
    refute text =~ "--append --body"
    assert text =~ ~s{"Principles/Baseline" --append -`}

    # A new Specification section is appended to an existing one: `page section` can't make one.
    assert text =~ ~s{"Specification/Features" --append -`}
    refute text =~ "Specification/<feature>"
  end

  test "its stage texts are the seed's stages, each short, and the file stays small" do
    text = skill()
    assert byte_size(text) < 12_000

    stages =
      for [_, name] <- Regex.scan(~r/^### (\w+)$/m, section(text, "## Stage texts")), do: name

    seed = for [_, name] <- Regex.scan(~r/^## (\w+)$/m, seed_playbook()), do: name
    assert stages == ["Grill", "Decide", "Principles", "Spec", "Cards"]
    assert Enum.all?(stages, &(&1 in seed))

    for stage <- stages do
      body = section(text, "### " <> stage)
      assert String.length(flat(body)) < 800, "#{stage}: #{String.length(flat(body))}"
    end
  end

  test "its baseline is the Handbook Tool's seed" do
    ours = sizes(section(skill(), "## The baseline"))
    seed = sizes(section(seed_playbook(), "## Sizing"))
    assert length(ours) == 3
    assert ours == seed
  end

  test "docs/agents.md, README and the manual name it and say when it runs" do
    agents = File.read!(Path.join(@root, "docs/agents.md"))
    assert agents =~ "| `slipdock-plan` | Planning:"
    assert agents =~ "## Planning an idea: the `slipdock-plan` skill"
    assert flat(agents) =~ "It is not used for \"add a card…\"."

    readme = flat(File.read!(Path.join(@root, "README.md")))
    assert readme =~ "**Planning.** The `slipdock-plan` skill runs when an agent is asked to plan"

    manual = flat(File.read!(Path.join(@root, "docs/manual.md")))
    assert manual =~ "**`slipdock-plan`** — planning, when an agent is asked to plan"
    assert manual =~ "not when asked for a card"
  end

  test "the agents help page lists it", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/help/agents/skills")
    text = html |> Floki.parse_document!() |> Floki.text() |> flat()
    assert text =~ "slipdock-plan: planning. Asked to plan"
    assert text =~ "A one-sentence ask stays one card"
  end

  describe "a board's enabled skills, served to its agents (#2063)" do
    test "docs/agents.md and the guide name each door and the plan skill's order" do
      agents = flat(File.read!(Path.join(@root, "docs/agents.md")))
      assert agents =~ "`GET /api/boards/:board/skills`, for anyone who reads the board"
      assert agents =~ "`slipdock skills board <board>`"
      assert agents =~ "MCP's is `get_guide` with `board`, which adds the same list as `skills`"
      assert agents =~ "the one enabled on the board from the skills registry"
      assert agents =~ "else one installed locally, else the stage's own text"
      refute agents =~ "uses the skill its section names when that skill is installed"

      guide = flat(SlipdockWeb.APIGuide.markdown())
      assert guide =~ "What the board's agents get is `GET /api/boards/:board/skills`"
      assert guide =~ "CLI: `slipdock skills board <board> [<name>]`"
      assert guide =~ "`get_guide` with `board`, whose answer adds the same list as `skills`"

      help = File.read!(Path.join(@root, "cli/help.txt"))
      assert help =~ "skills board <board> [<name>]"

      manual = flat(File.read!(Path.join(@root, "docs/manual.md")))
      assert manual =~ "**What the board's agents get.** `GET /api/boards/:board/skills`"
      assert manual =~ "the one enabled on the board first, else one installed on the machine"
      refute manual =~ "an installed skill named with `skill:`"

      readme = flat(File.read!(Path.join(@root, "README.md")))
      assert readme =~ "`slipdock skills board <board> [<name>]`"
      assert readme =~ "`slipdock-plan` uses one for a Playbook stage that names it"
    end

    test "the agents help page has the doors' row and the plan skill's order", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/help/agents")
      text = html |> Floki.parse_document!() |> Floki.text() |> flat()
      assert text =~ "Get the skills enabled on a board, each with its pinned text"
      assert text =~ "GET /api/boards/:board/skills"
      assert text =~ "get_guide's board"
      assert text =~ "slipdock skills board"

      {:ok, _view, html} = live(conn, ~p"/help/agents/skills")
      text = html |> Floki.parse_document!() |> Floki.text() |> flat()
      assert text =~ "it uses the one enabled on the board from the skills registry"
      assert text =~ "else one installed on the machine, else its own text, and says which"
    end
  end
end
