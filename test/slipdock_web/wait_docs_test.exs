defmodule SlipdockWeb.WaitDocsTest do
  @moduledoc """
  Waits and pauses as the docs and skills describe them (#1119, R26): an
  agent stuck on a person opens a wait and stops, and one that sees
  `paused` takes nothing. Each document an agent or a person already reads
  says so — the short guide (still under its cap, every core heading kept),
  the full guide, the manual, README, docs/agents.md, both skills that work
  a board, /help/agents and the runner prompt itself.
  """
  use SlipdockWeb.ConnCase, async: true

  import Slipdock.DocsFacts, only: [assert_states: 2]

  import Slipdock.Fixtures

  @root Path.expand("../..", __DIR__)
  defp read(path), do: Slipdock.DocsText.read!(Path.join(@root, path))

  # A help page as the server sends it, without joining its LiveView: these
  # tests read what the page says, and a join refused under load came back
  # from `live/2` as a redirect to the page itself (#2639).
  defp help(conn, path), do: conn |> get(path) |> html_response(200)

  describe "the guide" do
    test "the short guide says to open a wait when stuck on a person, and to stop when paused" do
      short = SlipdockWeb.APIGuide.short()
      assert short =~ "**Stuck on a person**"
      assert short =~ ~s(open a\n  wait, `POST /api/cards/57/wait {"needs": "…"}`)
      assert_states(short, "If `paused` is set, take nothing and stop.")

      refute short =~
               ~s(**Stuck on a person** — a decision, a credential, an approval:\n  `{"add_flags": ["waiting"]})
    end

    test "the short guide stays under its cap with every core heading" do
      user = user_fixture()
      guide = SlipdockWeb.APIGuide.short(user: user)
      assert byte_size(guide) < 22_000

      for heading <- [
            "Over MCP",
            "Epics and subcards",
            "Choosing what to do next",
            "Working a card",
            "Your boards right now",
            "The rest of the guide"
          ] do
        assert guide =~ "\n## #{heading}\n", "#{heading} missing from the short guide"
      end

      assert byte_size(SlipdockWeb.APIGuide.markdown(user: user)) > 2 * byte_size(guide)
    end

    test "the full guide documents waits, Waiting on you, pauses and a card's state" do
      guide = SlipdockWeb.APIGuide.markdown()
      assert_states(guide, "### Waits, pauses and a card's state")
      assert guide =~ "B/api/cards/57/wait/answer"
      assert guide =~ "curl -s -X DELETE -H \"$H\" B/api/cards/57/wait"
      assert guide =~ "curl -s -H \"$H\" B/api/work"
      assert guide =~ "cards?stuck=true&driver=agent"
      assert guide =~ "`waiting_on_you`"
      assert_states(guide, "If it is\nset, take nothing and stop")
      # The runners section keeps the parking and pausing detail.
      assert guide =~ "**Parking on a question.**"
      assert guide =~ "**Pausing.**"
      assert guide =~ "`slipdock pause` and `slipdock resume`"
    end
  end

  test "the runner prompt says to open a wait and stop, and to take nothing more when paused" do
    text = Slipdock.Automations.Runner.unattended()

    assert text =~
             "open a wait (`slipdock wait <card> … --kind K` or update_card `wait` with `question`)"

    assert_states(text, "the answer starts a fresh job")
    # Its kind picks who is asked (#1949).
    assert_states(
      text,
      "(product, ux, security, release or other: the board sends each kind to its person)"
    )

    assert_states(text, "If the board answers `paused`, finish this card and take no other.")
  end

  describe "the manual, README and docs/agents.md" do
    test "the manual has the waits and flow sections, and the runner paragraphs" do
      manual = read("docs/manual.md")
      assert manual =~ ~r/^## Waiting on a person \(waits\)$/m
      # not a doc's wording: a section's heading, which the contents link to
      assert manual =~ ~r/^## Flow: the pulse, a card's state and its age$/m
      assert manual =~ ~s(slipdock wait 12 "Which region?" --on dana@example.com)
      assert manual =~ "slipdock answer 12 --choice 1"
      assert manual =~ "**Waiting on you.**"
      assert manual =~ "**Parked on a question.**"
      assert manual =~ "**Pausing.**"
      assert manual =~ "**WIP limits that hold automated work.**"
      assert manual =~ "slipdock cards <board> --stuck --driver agent"
      refute manual =~ "say what was chosen, or comment, flag the card `waiting` and stop"
    end

    test "README names waits, Waiting on you, parked jobs, pause and the pulse" do
      readme = read("README.md")
      assert readme =~ "docs/manual/waiting-on-a-person-waits.md"
      assert readme =~ "docs/manual/flow-the-pulse-a-cards-state-and-its-age.md"
      assert readme =~ "**Waiting on you**"
      assert readme =~ "**A question parks the job.**"
      assert readme =~ "**A brake with a reason.**"
      assert readme =~ "slipdock pulse <board>"
      assert_states(readme, "take\nnothing more once the board is paused")
    end

    test "docs/agents.md tells an agent to open a wait, and to stop on paused" do
      agents = read("docs/agents.md")
      assert agents =~ "it **opens a wait**"
      assert agents =~ "manual/waiting-on-a-person-waits.md"
      assert_states(agents, "An agent seeing it takes nothing and stops.")
      assert agents =~ "manual/flow-the-pulse-a-cards-state-and-its-age.md"
      refute agents =~ "or comment, flag the card `waiting` and stop"
    end

    # The anchors the others link to exist in the manual as GitHub makes them.
    test "every manual anchor linked here is a heading there" do
      headings =
        ~r/^## (.+)$/m
        |> Regex.scan(read("docs/manual.md"))
        |> Enum.map(fn [_, h] ->
          h
          |> String.downcase()
          |> String.replace(~r/[^a-z0-9 -]/, "")
          |> String.replace(" ", "-")
        end)

      for anchor <- ["waiting-on-a-person-waits", "flow-the-pulse-a-cards-state-and-its-age"] do
        assert anchor in headings, "no manual heading for ##{anchor}"
      end
    end
  end

  describe "the skills" do
    test "slipdock-loop stops on paused, and opens a wait to hand a decision back" do
      loop = read("priv/skills/slipdock-loop/SKILL.md")
      assert loop =~ "**`nothing queued to take: paused by …`**"
      assert_states(loop, "If the answer starts with a `PAUSED` line")
      assert loop =~ "open a wait and stop. `slipdock wait <id> \"the question\""
      # Waiting cards are still skipped by the flag the wait sets.
      assert_states(
        loop,
        "flagged `blocked` or `waiting` (an open wait\non a person sets `waiting` itself)"
      )
    end

    test "slipdock-work opens a wait, stops on paused and reads what is waiting on you" do
      work = read("priv/skills/slipdock-work/SKILL.md")
      assert work =~ "open a wait and stop (`slipdock wait"
      assert work =~ "If the\n  board answers `PAUSED`"
      assert work =~ "`slipdock work`: waits on you"
      assert work =~ "Open a wait (`slipdock wait <card> \"…\" --kind K`"
      assert_states(work, "ux, security, release, other) and stop: the job is parked")
    end

    test "the slipdock skill lists the wait, answer and work commands and the pause" do
      skill = read("priv/skills/slipdock/SKILL.md")
      assert skill =~ ~s(slipdock wait <id> "what you need" [--on EMAIL] [--choice X]...)
      assert skill =~ "slipdock answer <id> [\"text\"] [--choice N]"
      assert skill =~ "slipdock work [--board B] [--done]"
      assert skill =~ "slipdock finish-job <id> --status waiting --needs \"Q\""
      assert skill =~ "`PAUSED by …: reason`"
      assert skill =~ "slipdock pause <board> [--pool P] --reason"
    end
  end

  describe "/help/agents" do
    test "the comparison has the wait, waiting-on-you and pause rows", %{conn: conn} do
      html = help(conn, ~p"/help/agents")
      assert_states(html, "Wait on a person, and answer a wait")
      assert_states(html, "See what is waiting on you, and a board&#39;s pulse")
      assert_states(html, "Pause runner work, and see that it is paused")
      assert_states(html, "parks the job; the answer sends it again")
    end

    test "the runner, MCP and CLI pages say the same", %{conn: conn} do
      html = help(conn, ~p"/help/agents/runners")
      assert_states(html, "saying what it needs and stop")
      assert html =~ "takes nothing and stops"
      refute html =~ "flag the card <em>waiting</em> and stop"

      html = help(conn, ~p"/help/agents/mcp")
      assert html =~ "answer_wait"

      html = help(conn, ~p"/help/agents/cli")
      assert html =~ "slipdock answer"
      assert html =~ "slipdock pause"
    end
  end

  describe "a series of questions (#1220)" do
    test "the guides, manual, README and agents doc say to ask them one each, and how to skip" do
      short = SlipdockWeb.APIGuide.short()
      assert_states(short, ~s(Several questions go as `{"questions": ["…", "…"]}`, one each))

      guide = SlipdockWeb.APIGuide.markdown()
      assert_states(guide, "**Several questions** go in one wait as `questions`")
      assert guide =~ ~s(-d '{"answers": ["eu", "12"]}')
      assert guide =~ ~s(-d '{"skip": true}')
      assert guide =~ "curl -s -H \"$H\" B/api/cards/57/waits"

      manual = read("docs/manual.md")
      assert_states(manual, "A wait can ask **several questions** at once.")
      assert manual =~ "press **Ask** in the toolbar"
      assert manual =~ "**Questions asked before**"
      assert manual =~ "slipdock answer 12 --skip"

      assert_states(read("README.md"), "Several questions are asked as a numbered series")
      assert read("docs/agents.md") =~ "Several questions go\nas `questions`"
    end

    test "every skill that asks says to ask several one each" do
      assert read("priv/skills/slipdock/SKILL.md") =~ "--question Q --question Q"
      assert read("priv/skills/slipdock/SKILL.md") =~ "slipdock answer <id> --skip"
      assert read("priv/skills/slipdock-work/SKILL.md") =~ "never one block"
      assert read("priv/skills/slipdock-loop/SKILL.md") =~ "never one block"
    end

    test "the MCP and CLI pages name questions, answers and skip", %{conn: conn} do
      html = help(conn, ~p"/help/agents/mcp")
      assert html =~ "several questions go as <code>questions</code>"

      html = help(conn, ~p"/help/agents/cli")
      assert html =~ "<code>--question</code>"
      assert html =~ "<code>slipdock waits</code>"
    end
  end

  describe "who gets asked (#1949)" do
    defp flat(path), do: path |> read() |> String.replace(~r/\s+/, " ")

    test "the manual describes the routes, the fallback and every door" do
      manual = flat("docs/manual.md")
      assert_states(manual, "**Who gets asked.** Each wait says what kind of question it is")
      assert manual =~ "else to the board's owner"
      assert manual =~ "the [rejection limit](verified-work.md)'s wait asks as `release`"
      assert_states(manual, "comes off its routes, and the open waits on them go to the owner")
      assert manual =~ "slipdock set-board slipdock --route product=dana@example.com"
      assert_states(manual, "slipdock wait 12 \"Which pricing tier ships first?\" --kind product")
      assert manual =~ "`PATCH /api/boards/:board` with `wait_routes`"
      assert manual =~ "`update_board` `wait_routes` and `update_card` `wait` `question`"
    end

    test "docs/agents.md, the README and the API guide tell an agent to give its kind" do
      assert flat("docs/agents.md") =~ "**Give a wait its kind**: `question` (`--kind K`)"
      assert_states(flat("README.md"), "**Who gets asked**: a wait says its kind of question")
      guide = SlipdockWeb.APIGuide.markdown()
      assert guide =~ ~s|"question": "product"|
      assert guide =~ ~s|{"wait_routes": {"product": ["dana@example.com"], "release": []}}|
    end

    test "both skills tell an agent to give its wait a kind, and list the kinds" do
      loop = flat("priv/skills/slipdock-loop/SKILL.md")
      assert loop =~ "Give it its kind, `--kind product|ux|security|release|other`"
      work = flat("priv/skills/slipdock-work/SKILL.md")
      assert work =~ "give its kind, `--kind product|ux|security|release|other`"
      assert_states(work, "K one of product, ux, security, release, other")
    end

    test "the CLI's help and the in-app help name --route and --kind", %{conn: conn} do
      help = read("cli/help.txt")
      assert help =~ "--route KIND=EMAIL[,EMAIL]: who a wait asking that"
      assert help =~ "[--kind K]"

      html = help(conn, "/help/boards")
      assert html =~ "Who gets asked"
      cli = help(conn, "/help/agents/cli")
      assert cli =~ "<code>--kind</code>"
    end
  end

  describe "an answer goes to any free runner (#2896)" do
    test "the guide, the manual, the README and docs/agents.md say it isn't held for the asker" do
      assert_states(
        SlipdockWeb.APIGuide.markdown(),
        "pool's queue for any free runner, not held for the runner that asked"
      )

      manual = read("docs/manual/waiting-on-a-person-waits.md")

      assert_states(
        manual,
        "for any free runner of the pool: it isn't held for the runner that asked"
      )

      assert_states(manual, "the card is not on anyone's *Waiting on you*")

      assert_states(
        read("README.md"),
        "for any free runner of the pool, not only the one that asked"
      )

      assert_states(
        read("docs/agents.md"),
        "any free runner of the pool, not held for the one that asked"
      )

      assert_states(
        read("docs/manual/the-health-monitor.md"),
        "a held answer waiting for the job a runner has on its card"
      )
    end

    test "the README and the slipdock skill say a feed's answer may be open beside its card" do
      both =
        ~r/an answered question's job may be open\s+beside\s+the card (it|the feed) sent,\s+and (it|the feed) sends the next card once both have closed/

      assert read("README.md") =~ both
      assert read("priv/skills/slipdock/SKILL.md") =~ both

      refute read("README.md") =~
               ~r/keeps one job open at a time, always for the top\s+ready card of the list, so/
    end

    test "the runners page and the flow page say so", %{conn: conn} do
      assert_states(
        help(conn, "/help/agents/runners"),
        "for any free runner of the pool: it isn't held for the runner that asked"
      )

      assert_states(help(conn, "/help/agents/flow"), "to whichever runner of the pool is free")
    end
  end
end
