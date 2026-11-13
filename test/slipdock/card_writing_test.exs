defmodule Slipdock.CardWritingTest do
  # How an agent writes on a card (#3001): every runner, verify and audit
  # job is told to write each field as Markdown a person can skim (lists, not
  # one dense paragraph) and to set out a question's options and recommend
  # one; the skills and the docs places say the same. Reads priv/skills/ and
  # docs/, so it is on test/repo_checks.txt.
  use Slipdock.DataCase, async: true

  import Slipdock.DocsFacts, only: [assert_states: 2]
  import Slipdock.Fixtures

  alias Slipdock.{Repo, Verified}
  alias Slipdock.Automations.Runner
  alias Slipdock.Runners.Job

  @root Path.expand("../..", __DIR__)

  @fields ["description", "bar", "evidence", "comments", "handoffs", "wait questions"]

  defp read(path), do: File.read!(Path.join(@root, path))
  defp flat(text), do: String.replace(text, ~r/\s+/, " ")

  describe "the paragraph" do
    test "names every field the agent writes, and asks for lists, not a dense paragraph" do
      text = Runner.writing()
      assert_states(text, "Write everything you put on the card as Markdown for a person to skim")

      for field <- @fields ++ ["status updates", "a verdict's reason"],
          do: assert(text =~ field, "writing/0 doesn't name #{field}")

      assert_states(text, "never one dense paragraph")
      assert_states(text, "where a list doesn't fit, short separate paragraphs")
    end

    test "sends long text through stdin, the question included" do
      text = Runner.writing()
      for flag <- ~w(--body --evidence --bar --reason), do: assert(text =~ "`#{flag} -`")
      assert text =~ "`slipdock wait <card> -`"
      assert text =~ "quoted heredoc"
    end

    test "has a question set out its options and recommend one" do
      text = Runner.writing()
      assert_states(text, "A question for a person lists each option and what it would mean")
      assert_states(text, "and recommends one")
      assert text =~ "`--default N`"
      assert text =~ "update_card `wait` `choices` and `default`"
    end
  end

  describe "the prompts" do
    setup do
      owner = user_fixture()
      board = board_fixture(%{"name" => "Writers"}, owner: owner)
      card = card_fixture(hd(board.columns), %{"title" => "Tidy the footer"})
      %{board: board, card: card}
    end

    test "every runner job's prompt carries it, before card text is data", ctx do
      rule =
        rule_fixture(ctx.board, %{
          "trigger" => %{"type" => "schedule", "at" => "23:59"},
          "actions" => [%{"type" => "runner", "pool" => "dev"}]
        })

      assert [{:ok, _}] =
               Runner.run(rule, %{type: "card_updated", card: ctx.card, board_id: ctx.board.id})

      [job] = Repo.all(Job)
      assert job.prompt =~ Runner.writing()

      assert String.ends_with?(
               Runner.unattended(),
               Runner.writing() <> "\n\n" <> Runner.card_text()
             )
    end

    test "the verify and audit prompts carry it", ctx do
      for prompt <- [
            Verified.verify_prompt(ctx.card, ctx.board),
            Verified.audit_prompt(ctx.card, ctx.board)
          ],
          do: assert(prompt =~ Runner.writing())
    end
  end

  describe "the skills" do
    test "slipdock-loop says every field reads like a comment, and how a question reads" do
      text = read("priv/skills/slipdock-loop/SKILL.md")
      assert_states(text, "**Every other field reads the same.**")
      assert_states(text, "**A question explains its options and recommends one.**")
      assert text =~ "slipdock wait <id> - --kind ux --choice"
      assert text =~ "I recommend **Inline**"

      for flag <- ~w(--desc --bar --evidence --no-code --reason),
          do: assert(text =~ "`#{flag} -`", "slipdock-loop doesn't send #{flag} on stdin")
    end

    test "slipdock-work says every field is Markdown, and how a question reads" do
      text = read("priv/skills/slipdock-work/SKILL.md") |> flat()
      assert_states(text, "**Everything you write on a card is Markdown, and is skimmed.**")
      assert_states(text, "**A question for a person explains its options and recommends one.**")
      assert text =~ "`--choice A --choice B --default 1`"
      assert text =~ "`slipdock wait <id> -`"
    end
  end

  describe "the MCP tool" do
    test "update_card's wait asks for the options and a recommendation" do
      needs =
        SlipdockWeb.MCP.Tools.UpdateCard.input_schema().properties.wait.properties.needs.description

      assert needs =~ "in Markdown"
      # not a doc: the tool's own schema
      assert needs =~ "each option and what it means"
      assert needs =~ "the one you recommend"
    end
  end

  describe "the docs places" do
    test "docs/agents.md says how a question and every field read" do
      text = read("docs/agents.md") |> flat()
      assert_states(text, "**How a question reads** (#3001)")
      assert_states(text, "**Everything an agent writes on a card is Markdown** (#3001)")
      assert text =~ "`Slipdock.Automations.Runner.writing/0`"
      assert_states(text, "The job logs are the agent's own and are shown as they are.")
    end

    test "the API guide says every field is Markdown and a question recommends one" do
      text = SlipdockWeb.APIGuide.markdown() |> flat()
      assert_states(text, "**Every field you write is Markdown too** (#3001)")
      assert_states(text, "**How a question reads** (#3001)")
      assert_states(text, "A question for a person explains its options and recommends one")
      assert_states(text, "like every field you write (bar, evidence, a question)")

      assert_states(text, "then how to write on the card (#3001")
      assert_states(text, "The card shows the evidence and the reason as Markdown")
    end

    test "the manual says what is shown as Markdown, and what the prompt says" do
      waits = read("docs/manual/waiting-on-a-person-waits.md") |> flat()
      assert_states(waits, "The question is shown as Markdown (#3001)")
      assert_states(waits, "`slipdock wait 12 - --choice … --default 2`")

      verified = read("docs/manual/verified-work.md") |> flat()
      assert_states(verified, "A written bar is shown as Markdown (#3001)")
      assert_states(verified, "The card panel shows the evidence, its *No code* reason")

      runners = read("docs/manual/runners.md") |> flat()
      assert_states(runners, "Then it says **how to write on the card** (#3001)")

      brief = read("docs/manual/every-feature-in-brief.md") |> flat()
      assert_states(brief, "The question is shown as Markdown.")
      assert_states(brief, "The card shows the bar, the evidence and a verdict's reason as")
      assert_states(brief, "set out a question's options and recommend one (#3001)")
    end

    test "the in-app help's building stage says so" do
      text = read("lib/slipdock_web/live/help_live/flow/stages/building.html.heex") |> flat()
      assert_states(text, "Everything it writes on the card is Markdown")
      assert_states(text, "A question sets out each option and what it would mean")
    end

    test "the CLI's help gives the question on stdin" do
      text = read("cli/help.txt") |> flat()
      assert_states(text, ~s("-" reads the question from stdin))
    end
  end
end
