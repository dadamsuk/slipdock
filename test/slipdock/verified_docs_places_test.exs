defmodule Slipdock.VerifiedDocsPlacesTest do
  @moduledoc """
  SPEC-10 checked by enumeration (#2694): for a card whose paths fall in
  SPEC-10's scope, the verify and audit prompts tell the verifier to take
  the names the diff introduces or alters, grep them across the seven docs
  places, and give each place one of four results; the builder's claimed
  prompt tells it the same, and that a place left out goes on the deferral
  card's bar. A card outside the scope, or a handbook without SPEC-10,
  gets none of it.
  """
  use Slipdock.DataCase, async: true

  import Slipdock.DocsFacts, only: [assert_states: 2]

  import Slipdock.Fixtures

  alias Slipdock.{Actor, Boards, Handbook, Repo, Runners, Verified, Wiki}
  alias Slipdock.Boards.Card

  @places [
    "README.md",
    "docs/manual.md docs/manual/",
    "lib/slipdock_web/live/help_live/guides.ex lib/slipdock_web/live/help_live/guides/",
    "lib/slipdock_web/live/help_live/agents.ex lib/slipdock_web/live/help_live/agents/ lib/slipdock_web/live/help_live/flow.ex lib/slipdock_web/live/help_live/flow/ cli/help.txt",
    "docs/agents.md",
    "lib/slipdock_web/api_guide.ex lib/slipdock_web/api_guide/",
    "priv/skills/"
  ]

  setup do
    owner = user_fixture("docs-places-owner@example.com")
    board = board_fixture(%{"name" => "Places", "code" => unique_code()}, owner: owner)
    {:ok, board} = Boards.update_board(board, %{"verify_work" => true})
    {:ok, _} = Handbook.install(owner, board)
    board = Boards.get_board!(board.id)
    doing = Enum.find(board.columns, &(&1.category == "doing"))

    agent = fn label ->
      %{Actor.unknown() | kind: "agent", via: "mcp", user_id: owner.id, agent: label}
    end

    %{owner: owner, board: board, doing: doing, builder: agent.("b"), checker: agent.("c")}
  end

  defp spec_rules(board, rules) do
    spec = Enum.find(Handbook.find(board).pages, &(&1.title == "Specification"))

    {:ok, _} =
      Wiki.update_page(spec, %{
        "front_matter" => "---\nhandbook: specification\n---\n",
        "body" => "# Specification\n\n## Rules\n\n" <> rules
      })
  end

  @spec10 "- **SPEC-10** must · scope lib/**, cli/**, priv/skills/** · judgement · Docs everywhere.\n"
  @spec1 "- **SPEC-1** must · scope lib/** · judgement · Every door.\n"

  defp card(ctx, paths) do
    card = card_fixture(ctx.doing, %{"title" => "A change"})
    {:ok, card} = Boards.Cards.update_card(card, %{"paths" => paths}, by: ctx.owner)
    card
  end

  defp submit(ctx, card) do
    {:ok, card} =
      Boards.Cards.update_card(
        Repo.get!(Card, card.id),
        %{"completed" => true, "evidence" => "built", "evidence_commit" => "abc1234"},
        actor: ctx.builder,
        by: ctx.owner
      )

    assert card.verify_state == "pending"
    card
  end

  defp claimed(card) do
    {:ok, job} = Runners.queue(card, %{pool: "dev", kind: "claude", prompt: "Do it."})
    Runners.claimed_prompt(job)
  end

  describe "the places" do
    test "are the seven, each with every file and directory its prose is in" do
      assert Enum.map(Verified.docs_places(), &elem(&1, 1)) == @places
      # The API guide's prose is a Markdown file per section (#2924).
      assert {"the API guide", "lib/slipdock_web/api_guide.ex lib/slipdock_web/api_guide/"} in Verified.docs_places()

      # Every file and directory a place names is there to grep.
      for files <- @places, path <- String.split(files), do: assert(File.exists?(path), path)
    end
  end

  describe "the verify and audit prompts" do
    test "a card in SPEC-10's scope gets the enumeration: names, seven places, four results",
         ctx do
      spec_rules(ctx.board, @spec10)
      card = submit(ctx, card(ctx, ["cli/lib/**"]))
      prompt = Verified.verify_prompt(card, ctx.board)

      assert_states(
        prompt,
        "The docs places (SPEC-10). This card's paths fall in SPEC-10's scope"
      )

      assert_states(prompt, "enumerating them, not by judging them")
      # The names, from the diff.
      assert prompt =~ "git diff $(git merge-base origin/<default branch> abc1234) abc1234"
      assert_states(prompt, "commands, flags and switches, MCP tool names")
      assert prompt =~ "settings, page and section names"
      # The seven places, numbered, each with its files.
      assert prompt =~ "The places, seven:"

      for {files, n} <- Enum.with_index(@places, 1),
          do: assert(prompt =~ ~r/ #{n}\. [^\n]*`#{Regex.escape(files)}`\n/)

      refute prompt =~ "8. the"
      # The four results.
      assert prompt =~ "- `updated`: the change edits it"

      assert_states(
        prompt,
        "- `deferred to #N`: the builder left it to card #N, and #N's bar names this place"
      )

      assert_states(
        prompt,
        "A deferral to a card whose bar doesn't name the place doesn't count: it is `missing`"
      )

      assert prompt =~ "- `n/a`, with why"
      assert prompt =~ "- `missing`: none of these."
      # One missing is SPEC-10 broken, with the place and the name.
      assert prompt =~ "One `missing` is a rejection"
      assert prompt =~ "`--check rule:SPEC-10=broken:<place's file>:<the name it lacks>`"
      assert prompt =~ "Step: `checking the docs places`"

      # It comes after the rules step and before the Handbook line.
      [rules, places, line] =
        Enum.map(
          ["The rules. In the clean tree", "The docs places (SPEC-10)", "The Handbook line."],
          fn text -> prompt |> :binary.match(text) |> elem(0) end
        )

      assert rules < places and places < line
      # The decision is still the step after the last check.
      assert prompt =~ ~r/\n6\. The docs places/
      assert prompt =~ ~r/\n7\. The Handbook line\. Find/
      assert prompt =~ ~r/\n8\. Decide once/

      {:ok, accepted} =
        Verified.decide(
          Repo.get!(Card, card.id),
          "accept",
          %{"checks" => ["bar:1=ok"]},
          ctx.checker,
          ctx.owner
        )

      audit = Verified.audit_prompt(accepted, ctx.board)
      assert_states(audit, "The docs places (SPEC-10). This card's paths fall in SPEC-10's scope")
      for files <- @places, do: assert(audit =~ "`#{files}`")

      assert_states(
        audit,
        "- `deferred to #N`: the builder left it to card #N, and #N's bar names this place"
      )

      assert audit =~ "One `missing` is a disagreement"
      refute audit =~ "One `missing` is a rejection"
    end

    test "a card outside SPEC-10's scope gets no docs-places step", ctx do
      spec_rules(ctx.board, @spec10)
      card = submit(ctx, card(ctx, ["test/**", "docs/manual/verified-work.md"]))

      assert Verified.docs_places_scope(card, Handbook.find(ctx.board)) == :out
      prompt = Verified.verify_prompt(card, ctx.board)
      assert_states(prompt, "The rules. In the clean tree")
      refute prompt =~ "docs places"
      refute prompt =~ "checking the docs places"
    end

    test "a handbook without SPEC-10 gets none, whatever the paths", ctx do
      spec_rules(ctx.board, @spec1)
      card = submit(ctx, card(ctx, ["lib/**"]))

      assert Verified.docs_places_scope(card, Handbook.find(ctx.board)) == :out
      refute Verified.verify_prompt(card, ctx.board) =~ "docs places"
      # Not even for a card with no paths, which would otherwise get it.
      assert Verified.docs_places_scope(card(ctx, []), Handbook.find(ctx.board)) == :out
    end

    test "no handbook, no step", ctx do
      assert Verified.docs_places_scope(card(ctx, ["lib/**"]), nil) == :out
    end

    test "a card with no paths gets the step, left to its diff's rules", ctx do
      spec_rules(ctx.board, @spec10)
      card = submit(ctx, card(ctx, []))

      assert Verified.docs_places_scope(card, Handbook.find(ctx.board)) == :unknown
      prompt = Verified.verify_prompt(card, ctx.board)
      assert_states(prompt, "If the rules above list SPEC-10 (the card declared no paths")
      refute prompt =~ "This card's paths fall in SPEC-10's scope"
      assert prompt =~ "Step: `checking the docs places`"
    end
  end

  describe "the builder's prompt" do
    test "a card in scope is told the enumeration and to list each left-out place on the deferral card's bar",
         ctx do
      spec_rules(ctx.board, @spec10)
      text = claimed(card(ctx, ["lib/slipdock/verified.ex", "test/**"]))

      assert text =~ Verified.docs_places_builder()
      builder = Verified.docs_places_builder()
      assert builder =~ "The docs places (SPEC-10)"
      for files <- @places, do: assert(builder =~ "`#{files}`")
      assert_states(builder, "updated, deferred to #N, n/a with why, or missing")
      assert_states(builder, "list each left-out place on that card's bar, by name")

      assert_states(
        builder,
        "A deferral to a card whose bar doesn't list the place doesn't count"
      )
    end

    test "a card outside the scope, or with no paths, isn't", ctx do
      spec_rules(ctx.board, @spec10)
      refute claimed(card(ctx, ["test/**"])) =~ "The docs places"
      refute claimed(card(ctx, [])) =~ "The docs places"
    end

    test "a handbook without SPEC-10 isn't", ctx do
      spec_rules(ctx.board, @spec1)
      refute claimed(card(ctx, ["lib/**"])) =~ "The docs places"
    end
  end
end
