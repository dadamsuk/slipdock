defmodule SlipdockWeb.WaitRuleDocsTest do
  @moduledoc """
  When an agent waits, and when it reads the obvious way and carries on
  (#2096), said the same everywhere an agent or a person reads it: a locked
  bar item made moot by a later, cited decision or rule is read the obvious
  way and noted, not waited on; what a wait is for; a wait offering choices
  names its default; an open wait is checked for being live first and a
  moot one withdrawn with a reason; and a board's `wait_default_after`.
  In both skills that work a board (`priv/skills`, the one source), the
  guide's short part and its waits section, docs/agents.md, the manual,
  the verifier's prompt, the flow help page and the Playbook seed.
  """
  use SlipdockWeb.ConnCase, async: true

  import Slipdock.DocsFacts, only: [assert_states: 2]

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Boards, Verified}
  alias SlipdockWeb.APIGuide

  @root Path.expand("../..", __DIR__)

  defp read(path), do: Slipdock.DocsText.read!(Path.join(@root, path))
  # Line breaks folded, for prose that is rewrapped as it changes.
  defp flat(text), do: String.replace(text, ~r/\s+/, " ")
  defp skill(name), do: flat(read("priv/skills/#{name}/SKILL.md"))

  describe "the skills that work a board" do
    for name <- ~w(slipdock-work slipdock-loop) do
      test "#{name} reads a moot bar item the obvious way, noted, not waited on" do
        text = skill(unquote(name))
        assert_states(text, "**A bar item made moot is read the obvious way, not waited on")
        assert_states(text, "locked bar item that a later decision or rule has made moot")
        assert_states(text, "Say so on the card (what you read, why, the citation)")
        assert_states(text, "accepts a noted reading and rejects one that wasn't noted")
      end

      test "#{name} says what a wait is for, and that one names its default" do
        text = skill(unquote(name))

        assert_states(
          text,
          "readings that differ materially in cost or in what the person sees"
        )

        assert text =~ "(product, ux, security, release)"
        assert_states(text, "(merging, changing a handbook rule, deploying)")
        assert_states(text, "names the default you would take")
        assert text =~ "`--default N` (`wait` `default`"
        assert text =~ "`wait_default_after`"
      end

      test "#{name} checks an open wait is live first, and withdraws a moot one with why" do
        text = skill(unquote(name))
        assert_states(text, "**An open wait: check it is still live, before anything else.**")

        assert text =~ "the question answered elsewhere"

        assert_states(text, "the cited rule or decision now in place")
        assert_states(text, "by whichever agent finds it, not only")
        assert text =~ ~s(`slipdock wait <id> --withdraw --reason "…"`)
        assert text =~ "`wait: null` with `wait_reason`"
        assert_states(text, "another agent's wait is refused without the reason")
      end
    end
  end

  describe "the guide" do
    test "its waits section says when to wait, and that a moot wait clears itself" do
      text = flat(APIGuide.markdown())
      assert_states(text, "**When to wait, and when not.** A wait is for readings that differ")
      assert_states(text, "accepts a noted reading and rejects one that wasn't noted")
      assert_states(text, "names the default you would take as `default`")
      assert text =~ "**A moot wait clears itself.**"
      assert text =~ "`DELETE /api/cards/:id/wait?reason=…`"
      assert text =~ "is refused (422) without a reason"
      assert text =~ "A board's `wait_default_after` (off unless set"

      assert_states(
        text,
        "Never for a product, ux, security or release question, nor a wait with no default."
      )
    end

    test "the short guide points at it from Stuck on a person, within its caps" do
      short = APIGuide.short()

      assert_states(flat(short), "**A bar item made moot** by a later, cited decision or rule")
      assert byte_size(short) < 22_000
      assert short |> String.split() |> length() < 4_500
    end
  end

  test "docs/agents.md says the same" do
    text = flat(read("docs/agents.md"))

    assert_states(
      text,
      "**When to wait, and when not.** A wait is for readings that differ materially"
    )

    assert_states(text, "accepts a noted reading and rejects one that wasn't noted")
    assert text =~ "--choice A --choice B --default 1"
    assert text =~ "**A moot wait clears itself.**"
    assert text =~ ~s(`slipdock wait <id> --withdraw --reason "…"`)
    assert text =~ "`slipdock set-board <board> --wait-default-after 4h`"

    assert_states(
      text,
      "Never for a product, ux, security or release question, nor a wait with no default."
    )
  end

  test "the manual describes the board setting at its doors" do
    text = flat(read("docs/manual.md"))
    assert_states(text, "**When an agent waits, and when it carries on.**")
    assert text =~ "**A moot wait clears itself.**"
    assert text =~ "**An approval's proposal stands after**"
    assert text =~ "`slipdock set-board slipdock --wait-default-after 4h`"
    assert text =~ ~s(`PATCH /api/boards/:board {"wait_default_after": "4h"}`)
    assert text =~ "`update_board` `wait_default_after`"
    assert text =~ "It is off until set."
    assert_states(text, "always waits for a person, however long it takes")
  end

  describe "the other places a reader looks for waits" do
    test "the README names --default, withdrawing with a reason and wait_default_after" do
      text = flat(read("README.md"))
      assert_states(text, "names the one the agent proposes (`--default N`, `default`)")
      assert text =~ ~s(`slipdock wait 12 --withdraw --reason "…"`)

      assert_states(
        text,
        "**An approval's proposal stands after** a board's `wait_default_after`"
      )

      assert text =~ "`slipdock set-board --wait-default-after 4h`; off until set"
      assert text =~ "never for the other kinds"
    end

    test "the slipdock skill gives --default, --reason and the board setting" do
      text = read("priv/skills/slipdock/SKILL.md")

      assert text =~
               ~s(slipdock wait <id> "what you need" [--on EMAIL] [--choice X]... [--default N] [--kind K])

      assert text =~ ~s(slipdock wait <id> --withdraw [--reason "why"])

      assert_states(
        flat(text),
        "an agent withdrawing one it didn't open (a moot wait) must give the reason"
      )

      assert text =~ "slipdock set-board <board> --wait-default-after 4h"
      refute text =~ ~r/slipdock wait <id> --withdraw\s+#/
    end

    test "the boards help names the proposal-stands setting beside Who gets asked",
         %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/help/boards")
      text = flat(html)

      assert_states(
        text,
        "<em>An approval&#39;s proposal stands after</em> (off until set; 4h, say)"
      )

      assert_states(text, "the card says so and the person asked is told")
      assert text =~ "always wait for a person"
    end
  end

  describe "the verifier's prompt" do
    setup %{user: owner} do
      board = board_fixture(%{"name" => "Verified"}, owner: owner)
      card = card_fixture(hd(board.columns), %{"title" => "Copies", "bar" => "1. Both copies"})
      %{board: board, card: card, owner: owner}
    end

    test "accepts a noted obvious reading of a moot bar item, and rejects an unnoted one",
         ctx do
      sentence = Verified.moot_bar_sentence()

      assert_states(
        sentence,
        "is met by its obvious reading when the card or the evidence says so"
      )

      assert_states(sentence, "what was read, why, and the decision or rule cited")
      assert_states(sentence, "accept it if the citation holds")
      assert_states(sentence, "An item read another way without such a note is a rejection")

      assert Verified.verify_prompt(ctx.card, ctx.board) =~ sentence

      {:ok, _} = Slipdock.Handbook.install(ctx.owner, ctx.board)
      board = Boards.get_board!(ctx.board.id)
      assert Verified.verify_prompt(ctx.card, board) =~ sentence
    end
  end

  test "the flow help page says what a wait is for and names the setting", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/help/agents/flow")
    text = flat(html)
    assert_states(text, "A wait is for what is yours to decide")
    assert_states(text, "A bar item a later decision made moot isn&#39;t one")
    assert_states(text, "names the one the agent proposes, so your answer can be one click")
    assert_states(text, "is withdrawn by the next agent to find it, with a comment saying why")
    assert text =~ "slipdock set-board B --wait-default-after 4h"
  end

  test "the Playbook seed's Card shape carries the bar line" do
    page = Enum.find(Slipdock.Handbook.blueprint()["pages"], &(&1["title"] == "Playbook"))

    assert_states(
      flat(page["body"]),
      "**A bar item made moot** by a later, cited decision or rule: read it the obvious way and say so. Not a wait."
    )
  end
end
