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

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  @root Path.expand("../..", __DIR__)
  defp read(path), do: File.read!(Path.join(@root, path))

  describe "the guide" do
    test "the short guide says to open a wait when stuck on a person, and to stop when paused" do
      short = SlipdockWeb.APIGuide.short()
      assert short =~ "**Stuck on a person**"
      assert short =~ ~s(open a\n  wait, `POST /api/cards/57/wait {"needs": "…"}`)
      assert short =~ "If `paused` is set, take nothing and stop."

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
      assert guide =~ "### Waits, pauses and a card's state"
      assert guide =~ "B/api/cards/57/wait/answer"
      assert guide =~ "curl -s -X DELETE -H \"$H\" B/api/cards/57/wait"
      assert guide =~ "curl -s -H \"$H\" B/api/work"
      assert guide =~ "cards?stuck=true&driver=agent"
      assert guide =~ "`waiting_on_you`"
      assert guide =~ "If it is\nset, take nothing and stop"
      # The runners section keeps the parking and pausing detail.
      assert guide =~ "**Parking on a question.**"
      assert guide =~ "**Pausing.**"
      assert guide =~ "`slipdock pause` and `slipdock resume`"
    end
  end

  test "the runner prompt says to open a wait and stop, and to take nothing more when paused" do
    text = Slipdock.Automations.Runner.unattended()
    assert text =~ "open a wait (`slipdock wait <card> …` or update_card `wait`)"
    assert text =~ "the answer starts a fresh job"
    assert text =~ "If the board answers `paused`, finish this card and take no other."
  end

  describe "the manual, README and docs/agents.md" do
    test "the manual has the waits and flow sections, and the runner paragraphs" do
      manual = read("docs/manual.md")
      assert manual =~ ~r/^## Waiting on a person \(waits\)$/m
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
      assert readme =~ "docs/manual.md#waiting-on-a-person-waits"
      assert readme =~ "docs/manual.md#flow-the-pulse-a-cards-state-and-its-age"
      assert readme =~ "**Waiting on you**"
      assert readme =~ "**A question parks the job.**"
      assert readme =~ "**A brake with a reason.**"
      assert readme =~ "slipdock pulse <board>"
      assert readme =~ "take\nnothing more once the board is paused"
    end

    test "docs/agents.md tells an agent to open a wait, and to stop on paused" do
      agents = read("docs/agents.md")
      assert agents =~ "it **opens a wait**"
      assert agents =~ "manual.md#waiting-on-a-person-waits"
      assert agents =~ "An agent seeing it takes nothing and stops."
      assert agents =~ "manual.md#flow-the-pulse-a-cards-state-and-its-age"
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
      assert loop =~ "If the answer starts with a `PAUSED` line"
      assert loop =~ "open a wait and stop. `slipdock wait <id> \"the question\""
      # Waiting cards are still skipped by the flag the wait sets.
      assert loop =~
               "flagged `blocked` or `waiting` (an open wait\non a person sets `waiting` itself)"
    end

    test "slipdock-work opens a wait, stops on paused and reads what is waiting on you" do
      work = read("priv/skills/slipdock-work/SKILL.md")
      assert work =~ "open a wait and stop (`slipdock wait"
      assert work =~ "If the\n  board answers `PAUSED`"
      assert work =~ "`slipdock work`: waits on you"
      assert work =~ "Open a wait (`slipdock wait <card> \"…\"`) and stop: the job is parked"
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
      {:ok, _view, html} = live(conn, ~p"/help/agents")
      assert html =~ "Wait on a person, and answer a wait"
      assert html =~ "See what is waiting on you, and a board&#39;s pulse"
      assert html =~ "Pause runner work, and see that it is paused"
      assert html =~ "parks the job; the answer sends it again"
    end

    test "the runner, MCP and CLI pages say the same", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/help/agents/runners")
      assert html =~ "saying what it needs and stop"
      assert html =~ "takes nothing and stops"
      refute html =~ "flag the card <em>waiting</em> and stop"

      {:ok, _view, html} = live(conn, ~p"/help/agents/mcp")
      assert html =~ "answer_wait"

      {:ok, _view, html} = live(conn, ~p"/help/agents/cli")
      assert html =~ "slipdock answer"
      assert html =~ "slipdock pause"
    end
  end
end
