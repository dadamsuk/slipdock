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

  import Slipdock.DocsFacts, only: [assert_states: 2, assert_states: 3]

  import Phoenix.LiveViewTest

  alias Slipdock.Handbook

  @root Path.expand("../..", __DIR__)
  @priv Path.join(@root, "priv/skills/slipdock-plan/SKILL.md")

  defp flat(text), do: text |> String.replace(~r/\s+/, " ") |> String.trim()
  defp skill, do: Slipdock.DocsText.read!(@priv)

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
    assert_states(flat, "**No handbook:** say so, and offer to install one")
    assert flat =~ "`install_tool` with `tool: \"handbook\"`"
    assert_states(flat, "Install it only when the person says yes")
    # The card-sized stop.
    assert_states(flat, "**Card-sized:** make the card as the Playbook's `## Card shape` says")
    assert flat =~ "and **stop**"
    # A named skill: enabled on the board, else installed, else the built-in
    # text, in that order, saying which (#2063).
    assert_states(flat, "When the section names one (`skill: <name>`), take the first of these")
    assert flat =~ "and say which you used"
    step = section(text, "## 3. Run the stages") |> flat()

    enabled =
      :binary.match(step, "1. **Enabled on the board.** `slipdock skills board <board> <name>`")

    installed = :binary.match(step, "2. **Installed here.**")
    neither = :binary.match(step, "3. **Neither:** use this file's text for the stage")
    assert [enabled, installed, neither] |> Enum.all?(&(&1 != :nomatch))
    assert elem(enabled, 0) < elem(installed, 0) and elem(installed, 0) < elem(neither, 0)
    assert step =~ "MCP: `get_guide` with `board`"
    assert_states(step, "a `changed` status means upstream moved on and the pinned text is still")
    # The Decision page's shape.
    assert flat =~ "titled `Decision: <what was chosen>`, with four parts: **Context**"
    assert_states(flat, "**The choice**, **Alternatives** (each, and why not), **Where decided**")
    # Principles are a person's call; the spec and the cards land where the Playbook says.
    assert_states(flat, "When the person agreed it in this conversation, append both")
    assert flat =~ "`slipdock garden propose <board> -`"
    assert flat =~ "--card <epic>"
    assert flat =~ "A default is never imposed."
  end

  test "its section writes are ones the CLI takes (#2039 trial)" do
    text = flat(skill())
    help = Slipdock.DocsText.read!(Path.join(@root, "cli/help.txt"))

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
    assert stages == ["Grill", "Spike", "Decide", "Principles", "Spec", "Cards"]
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

  test "docs/agents.md, the feature digest and the manual name it and say when it runs" do
    agents = Slipdock.DocsText.read!(Path.join(@root, "docs/agents.md"))
    assert agents =~ "| `slipdock-plan` | Planning:"
    assert agents =~ "## Planning an idea: the `slipdock-plan` skill"
    assert_states(flat(agents), "It is not used for \"add a card…\".")

    readme =
      flat(Slipdock.DocsText.read!(Path.join(@root, "docs/manual/every-feature-in-brief.md")))

    assert_states(
      readme,
      "**Planning.** The `slipdock-plan` skill runs when an agent is asked to plan"
    )

    manual = flat(Slipdock.DocsText.read!(Path.join(@root, "docs/manual.md")))
    assert_states(manual, "**`slipdock-plan`** — planning, when an agent is asked to plan")
    assert_states(manual, "not when asked for a card")
  end

  test "the agents help page lists it", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/help/agents/skills")
    text = html |> Floki.parse_document!() |> Floki.text() |> flat()
    assert text =~ "slipdock-plan: planning. Asked to plan"
    assert text =~ "A one-sentence ask stays one card"
  end

  describe "a board's enabled skills, served to its agents (#2063)" do
    test "docs/agents.md and the guide name each door and the plan skill's order" do
      agents = flat(Slipdock.DocsText.read!(Path.join(@root, "docs/agents.md")))
      assert_states(agents, "`GET /api/boards/:board/skills`, for anyone who reads the board")
      assert agents =~ "`slipdock skills board <board>`"

      assert_states(
        agents,
        "MCP's is `get_guide` with `board`, which adds the same list as `skills`"
      )

      assert_states(agents, "the one enabled on the board from the skills registry")
      assert_states(agents, "else one installed locally, else the stage's own text")
      refute agents =~ "uses the skill its section names when that skill is installed"

      guide = flat(SlipdockWeb.APIGuide.markdown())
      assert_states(guide, "What the board's agents get is `GET /api/boards/:board/skills`")
      assert guide =~ "CLI: `slipdock skills board <board> [<name>]`"

      assert_states(
        guide,
        "`get_guide` with `board`, whose answer adds the same list as `skills`"
      )

      help = Slipdock.DocsText.read!(Path.join(@root, "cli/help.txt"))
      assert help =~ "skills board <board> [<name>]"

      manual = flat(Slipdock.DocsText.read!(Path.join(@root, "docs/manual.md")))
      assert manual =~ "**What the board's agents get.** `GET /api/boards/:board/skills`"

      assert_states(
        manual,
        "the one enabled on the board first, else one installed on the machine"
      )

      refute manual =~ "an installed skill named with `skill:`"

      readme =
        flat(Slipdock.DocsText.read!(Path.join(@root, "docs/manual/every-feature-in-brief.md")))

      assert readme =~ "`slipdock skills board <board> [<name>]`"
      assert_states(readme, "`slipdock-plan` uses one for a Playbook stage that names it")
    end

    test "the agents help page has the doors' row and the plan skill's order", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/help/agents")
      text = html |> Floki.parse_document!() |> Floki.text() |> flat()
      assert_states(text, "Get the skills enabled on a board, each with its pinned text")
      assert text =~ "GET /api/boards/:board/skills"
      assert text =~ "get_guide's board"
      assert text =~ "slipdock skills board"

      {:ok, _view, html} = live(conn, ~p"/help/agents/skills")
      text = html |> Floki.parse_document!() |> Floki.text() |> flat()
      assert_states(text, "it uses the one enabled on the board from the skills registry")
      assert_states(text, "else one installed on the machine, else its own text, and says which")
    end
  end

  describe "the Grill asks in numbered rounds (#2065)" do
    test "the stage text has the rounds, the recommended answer, the one wait and the stop rule" do
      stage = skill() |> section("### Grill") |> flat()
      assert stage =~ "Ask in numbered rounds."
      refute stage =~ "one question at a time"
      assert_states(stage, "A round is every question whose prerequisites are settled")
      assert_states(stage, "numbered, each with the answer you recommend, so a yes is enough")

      assert_states(
        stage,
        "a round goes into one wait, a `--question` each with its recommended answer, never a wait per question"
      )

      assert_states(stage, "The answers settle the next round's prerequisites.")
      assert_states(stage, "Stop when the next answer wouldn't change the plan")

      assert_states(
        stage,
        "what is built, for whom, what done looks like and what is out of scope"
      )

      assert_states(
        stage,
        "Produce a brief: the problem, who it is for, done-when, out of scope, open questions."
      )
    end

    test "step 3 puts a round into one wait, with a command the CLI takes" do
      step = skill() |> section("## 3. Run the stages") |> flat()
      assert_states(step, "Put a grill round's or decide's questions, or the spike candidates,")

      assert step =~
               ~s{a numbered round (`slipdock wait <epic> "intro" --question Q --question Q --kind product`}

      assert_states(step, "a grill question's recommended answer in its text")
      assert_states(step, "the answer starts the next pass, and the grill's next round")

      # The skill's example names a skill by its front-matter name.
      assert_states(step, ~s{"Grill: `grilling`, enabled on this board from mattpocock/skills"})
      refute skill() =~ ~r/[\w-]+:grilling/

      help = Slipdock.DocsText.read!(Path.join(@root, "cli/help.txt"))
      assert help =~ "--question Q"
    end

    test "the seed's Grill and the skill's say the same three things" do
      {:ok, seed} = Slipdock.Wiki.Section.read(seed_playbook(), "Playbook/Grill")
      stage = skill() |> section("### Grill") |> flat()

      for said <- [
            "numbered rounds",
            "every question whose prerequisites are settled",
            "a round goes into one wait",
            "the next answer wouldn't change the plan"
          ] do
        assert_states(flat(seed), said, said)
        assert_states(stage, said, said)
      end
    end
  end

  describe "unattended: assume what the board answers, wait for the person's (#2067)" do
    # The skill's *Nobody there* bullet of step 3, flattened.
    defp nobody_there do
      step = skill() |> section("## 3. Run the stages") |> flat()
      [_, rest] = String.split(step, "- **Nobody there** (a runner job, a loop): ", parts: 2)
      [nobody, _] = String.split(rest, "- **Spikes stop the plan.**", parts: 2)
      nobody
    end

    test "step 3 answers from the board and marks each such answer (assumed)" do
      nobody = nobody_there()

      assert_states(
        nobody,
        "answer from the board what it answers (the card, the handbook, a Decision)"
      )

      assert_states(nobody, "mark each such answer *(assumed)* where you write it")
      assert nobody =~ "such answer *(assumed)*"
      assert String.starts_with?(nobody, "answer from the board")
    end

    test "step 3 never answers the person's decisions: one wait, a numbered round, and stop" do
      nobody = nobody_there()
      assert_states(nobody, "A decision that is the person's you never answer yourself.")
      assert nobody =~ "never answer yourself"
      assert nobody =~ "one wait, a numbered round (`slipdock wait <epic>"
      assert nobody =~ "--question Q --question Q --kind product"
      assert nobody =~ "and stop;"

      # The assumption comes before the wait: only what is left is asked.
      {assumed, _} = :binary.match(nobody, "*(assumed)*")
      {wait, _} = :binary.match(nobody, "as one wait")
      assert assumed < wait

      # The old rule, every question into a wait, is gone.
      refute nobody =~ "don't answer your own questions"
    end

    test "the Grill stage text says the same, in the one round" do
      stage = skill() |> section("### Grill") |> flat()
      [_, nobody] = String.split(stage, "Nobody there: ", parts: 2)
      assert String.starts_with?(nobody, "answer what the board answers, marked *(assumed)*;")
      assert nobody =~ "the person's decisions wait:"
      assert_states(nobody, "the person's decisions wait: a round goes into one wait")
      assert nobody =~ "never a wait per question"
    end

    test "the skill still never decides for the person" do
      never = skill() |> section("## What this never does") |> flat()
      assert never =~ "or decide for the person."
    end

    test "docs/agents.md's planning section says the same line" do
      agents = Slipdock.DocsText.read!(Path.join(@root, "docs/agents.md"))
      planning = agents |> section("## Planning an idea: the `slipdock-plan` skill") |> flat()
      [_, unattended] = String.split(planning, "Run unattended, it ", parts: 2)

      assert String.starts_with?(unattended, "answers from the board what the board answers")

      assert_states(
        unattended,
        "answers from the board what the board answers (the card, the handbook, a Decision)"
      )

      assert unattended =~ "marks each such answer *(assumed)*."
      assert unattended =~ "It opens one wait, as"
      assert unattended =~ "numbered round, only for decisions"
      assert unattended =~ "decisions that are the person's"
      assert unattended =~ "never answers those itself."
      refute planning =~ "it puts its questions in a wait"
    end

    test "the manual's skills page says it too" do
      manual = flat(Slipdock.DocsText.read!(Path.join(@root, "docs/manual/skills.md")))
      [_, unattended] = String.split(manual, "Run unattended, it ", parts: 2)
      [unattended, _] = String.split(unattended, "A question only building", parts: 2)
      assert_states(unattended, "answers from the board what the board answers")
      assert unattended =~ "marks each such answer *(assumed)*;"
      assert unattended =~ "it opens one wait, as"
      assert unattended =~ "numbered round, only for decisions"
      assert unattended =~ "decisions that are yours"
      assert unattended =~ "never answers those itself."
      refute manual =~ "it puts its questions in a wait"
    end
  end

  describe "the Spike stage (#2353)" do
    test "the skill has the three tests, the confirmation, the stop and the resume" do
      stage = skill() |> section("### Spike") |> flat()
      assert_states(stage, "only building answers it (not a person, not reading)?")
      assert_states(stage, ~s{A "no" changes the spec (say how)?})
      assert_states(stage, "counting flow time and lane contention as well as rework?")
      assert_states(stage, "Fails only the third: its card goes first in build order")
      assert_states(stage, "only those the person confirms become spikes")
      assert_states(stage, "None pass: skip the stage and say why")

      step = skill() |> section("## 3. Run the stages") |> flat()
      assert_states(step, "or the spike candidates, to the person as one wait")
      assert step =~ "--kind product"
      assert_states(step, "**Spikes stop the plan.** With spike cards made, stop")

      assert_states(
        step,
        ~s{slipdock handoff <epic> --next "Planning resumes at Spec once spikes #… are answered"}
      )

      assert_states(
        step,
        "**Resuming**, read each accepted spike's answer page and start at Spec"
      )

      assert_states(
        step,
        "An *inconclusive* answer goes to the person: another spike, the risky card first, or drop it"
      )

      write = skill() |> section("## 4. Write where the Playbook says") |> flat()
      assert write =~ "**The spikes:**"
      assert write =~ "no paths"
      assert write =~ "--profile spike --bar"
    end

    test "the spike's add command is one the CLI takes" do
      help = Slipdock.DocsText.read!(Path.join(@root, "cli/help.txt"))
      assert_states(help, "--profile P                 what kind of change it is")
      assert help =~ "--bar TEXT  --paths"
      assert "spike" in Slipdock.Profiles.names()
    end

    test "docs/agents.md, the API guide and the manual describe the stage" do
      agents = flat(Slipdock.DocsText.read!(Path.join(@root, "docs/agents.md")))
      assert_states(agents, "Grill, Spike, Decide, Principles, Spec, Cards for a system")
      assert_states(agents, "Grill, Spike, Spec, Cards for a feature")
      assert_states(agents, "**Spike** runs only when an open question passes three tests")
      assert agents =~ "Spikes answered (#…): resume planning"

      # The Profiles section, shown to a user with profiles on: read its source.
      guide = flat(Slipdock.DocsText.read!(Path.join(@root, "lib/slipdock_web/api_guide.ex")))
      assert guide =~ "the `slipdock-plan` skill's Spike stage"
      assert guide =~ "Spikes answered (#…): resume planning"
      assert guide =~ "Nothing resumes by itself"

      manual = flat(Slipdock.DocsText.read!(Path.join(@root, "docs/manual/skills.md")))
      assert_states(manual, "(grill, spike, decide, principles, spec, cards)")
      assert_states(manual, "becomes a `spike` subcard, once you confirm it")
    end

    test "the help pages describe it", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/help/agents/skills")
      text = html |> Floki.parse_document!() |> Floki.text() |> flat()
      assert_states(text, "(grill, spike, decide, principles, spec, cards)")
      assert_states(text, "planning stops until the spikes are answered")

      {:ok, _view, html} = live(conn, ~p"/help/agents/flow")
      text = html |> Floki.parse_document!() |> Floki.text() |> flat()
      assert_states(text, "An epic planned with the plan skill can start with spikes")
      assert text =~ "--profile spike"
      assert_states(text, "the Spec is written from the answers")
    end
  end
end
