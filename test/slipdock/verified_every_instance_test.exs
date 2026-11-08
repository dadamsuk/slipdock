defmodule Slipdock.VerifiedEveryInstanceTest do
  @moduledoc """
  Every instance of a broken rule in one rejection (#2046): the verify and
  audit prompts tell the verifier, once it finds a rule broken, to look for
  every other instance of the same break and name them all, each with file
  and line; a rule given broken more than once keeps every instance, and
  the rejection's comment lists them under the one rule.
  """
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Actor, Boards, Repo, Verified}
  alias Slipdock.Boards.Card
  alias Slipdock.Verified.Checks

  @readme "rule:SPEC-10=broken:README.md:40:lacks Playbook"
  @skill "rule:SPEC-10=broken:skills/slipdock-docs/SKILL.md:12:the same list"
  @help "rule:SPEC-10=broken:lib/slipdock_web/live/help_live/agents.ex:88"

  setup do
    owner = user_fixture("every-instance-owner@example.com")
    board = board_fixture(%{"name" => "Instances", "code" => unique_code()}, owner: owner)
    {:ok, board} = Boards.update_board(board, %{"verify_work" => true})
    doing = Enum.find(board.columns, &(&1.category == "doing"))
    card = card_fixture(doing, %{"title" => "Handbook pages"})

    agent = fn label ->
      %{Actor.unknown() | kind: "agent", via: "mcp", user_id: owner.id, agent: label}
    end

    %{
      owner: owner,
      board: board,
      card: card,
      builder: agent.("builder"),
      checker: agent.("checker")
    }
  end

  defp submit(ctx) do
    {:ok, card} =
      Boards.update_card(
        Repo.get!(Card, ctx.card.id),
        %{"completed" => true, "evidence" => "built", "evidence_commit" => "abc1234"},
        actor: ctx.builder,
        by: ctx.owner
      )

    assert card.verify_state == "pending"
    card
  end

  defp decide(ctx, decision, params),
    do: Verified.decide(Repo.get!(Card, ctx.card.id), decision, params, ctx.checker, ctx.owner)

  defp last_body(card),
    do: Boards.get_card!(card.id).comments |> Enum.max_by(& &1.id) |> Map.fetch!(:body)

  describe "Checks.parse/1" do
    test "a rule given broken more than once keeps every instance, in order" do
      assert {:ok, %{"rules" => [rule]}} = Checks.parse([@readme, @skill, @help])

      assert rule == %{
               "id" => "SPEC-10",
               "result" => "broken",
               "instances" => [
                 %{"file" => "README.md", "line" => 40, "note" => "lacks Playbook"},
                 %{
                   "file" => "skills/slipdock-docs/SKILL.md",
                   "line" => 12,
                   "note" => "the same list"
                 },
                 %{"file" => "lib/slipdock_web/live/help_live/agents.ex", "line" => 88}
               ]
             }
    end

    test "broken once, it keeps the plain shape" do
      assert {:ok, %{"rules" => [rule]}} = Checks.parse([@readme])

      assert rule == %{
               "id" => "SPEC-10",
               "result" => "broken",
               "note" => "README.md:40:lacks Playbook"
             }
    end

    test "an instance without a place keeps its note, and one with nothing is kept too" do
      assert {:ok, %{"rules" => [rule]}} =
               Checks.parse([
                 "rule:UX-4=broken:hex colours",
                 "rule:UX-4=broken:lib/a.ex:7",
                 "rule:UX-4=broken"
               ])

      assert rule["instances"] == [
               %{"note" => "hex colours"},
               %{"file" => "lib/a.ex", "line" => 7},
               %{}
             ]

      assert Checks.instances(rule) == [
               {nil, "hex colours"},
               {"lib/a.ex:7", nil},
               {nil, nil}
             ]
    end

    test "different rules stay apart, and a rule's verdict other than broken still replaces" do
      assert {:ok, %{"rules" => rules}} =
               Checks.parse([
                 @readme,
                 "rule:UX-4=broken:lib/a.ex:7",
                 @skill,
                 "rule:ARCH-1=ok",
                 "rule:ARCH-1=n/a"
               ])

      assert [%{"id" => "SPEC-10", "instances" => [_, _]}, %{"id" => "UX-4", "note" => _}, arch] =
               rules

      assert arch == %{"id" => "ARCH-1", "result" => "n/a"}
    end

    test "a broken line after an ok one for the same rule replaces it, as before" do
      assert {:ok, %{"rules" => [rule]}} = Checks.parse(["rule:SPEC-10=ok", @readme])

      assert rule == %{
               "id" => "SPEC-10",
               "result" => "broken",
               "note" => "README.md:40:lacks Playbook"
             }
    end

    test "the stored map, its instances included, is taken back as it was" do
      {:ok, stored} = Checks.parse([@readme, @skill, @help, "bar:1=ok"])
      assert {:ok, ^stored} = Checks.parse(stored)
    end

    test "the rule fails once, however many instances it has" do
      {:ok, checks} = Checks.parse([@readme, @skill, @help])
      assert Checks.failing(checks) == ["SPEC-10"]
      assert Checks.blocking(checks) == ["SPEC-10"]

      assert Checks.lines(checks) == [
               {"SPEC-10", "broken",
                "README.md:40 lacks Playbook; skills/slipdock-docs/SKILL.md:12 the same list; " <>
                  "lib/slipdock_web/live/help_live/agents.ex:88"}
             ]
    end

    test "instances/1 of a rule that isn't broken is empty" do
      assert Checks.instances(%{"id" => "UX-4", "result" => "ok"}) == []

      assert Checks.instances(%{"id" => "UX-4", "result" => "broken", "note" => "x"}) == [
               {nil, "x"}
             ]
    end
  end

  describe "Checks.markdown/1" do
    test "lists every instance under its one rule" do
      {:ok, checks} = Checks.parse(["bar:1=ok", @readme, @skill, @help, "rule:UX-4=broken:hex"])

      assert Checks.markdown(checks) ==
               """
               - bar 1: ok
               - SPEC-10: broken — 3 instances
                 - `README.md:40` — lacks Playbook
                 - `skills/slipdock-docs/SKILL.md:12` — the same list
                 - `lib/slipdock_web/live/help_live/agents.ex:88`
               - UX-4: broken — hex\
               """
    end

    test "is empty for no parts" do
      assert Checks.markdown(%{}) == ""
      assert Checks.markdown(nil) == ""
    end
  end

  describe "a rejection" do
    test "names every instance under the one rule id, and the verdict keeps them", ctx do
      submit(ctx)

      reason =
        "SPEC-10: the page list is stale in three places.\n" <>
          "Every instance: searched the repo for the page list; found these 3."

      {:ok, card} =
        decide(ctx, "reject", %{
          "reason" => reason,
          "checks" => ["bar:1=ok", @readme, @skill, @help]
        })

      assert card.verify_state == "rejected"
      assert [%{"id" => "SPEC-10", "instances" => [_, _, _]}] = card.verify_checks["rules"]

      body = last_body(card)
      assert body =~ "**Rejected** by"
      assert body =~ "Every instance: searched the repo for the page list; found these 3."

      assert body =~
               """
               - SPEC-10: broken — 3 instances
                 - `README.md:40` — lacks Playbook
                 - `skills/slipdock-docs/SKILL.md:12` — the same list
                 - `lib/slipdock_web/live/help_live/agents.ex:88`\
               """

      assert %{reason: ^reason} = Verified.rejection(card)
    end
  end

  describe "the prompts" do
    test "verify and audit, on a board with a handbook, tell it to name every instance", ctx do
      {:ok, _} = Slipdock.Handbook.install(ctx.owner, ctx.board)
      board = Boards.get_board!(ctx.board.id)
      card = submit(ctx)

      verify = Verified.verify_prompt(card, board)
      assert verify =~ Verified.every_instance_sentence()

      {:ok, accepted} = decide(ctx, "accept", %{"checks" => ["bar:1=ok"]})
      assert Verified.audit_prompt(accepted, board) =~ Verified.every_instance_sentence()

      sentence = Verified.every_instance_sentence()
      assert sentence =~ "look for every other instance of the same break"
      assert sentence =~ "(the same list, the same string, the same door)"
      assert sentence =~ "name them all in this one rejection"
      # The example: a list copied across docs, each copy its own line, file and line.
      assert sentence =~ "a page list copied across docs"
      assert sentence =~ "file and line each"
      assert sentence =~ "--check rule:SPEC-10=broken:README.md:40:lacks Playbook"
      assert sentence =~ ~r/--check rule:SPEC-10=broken:\S+SKILL.md:12:the same list/
      # And the rejection says it did so.
      assert sentence =~ "Say in the reason that you did (`Every instance:"
    end

    test "without a handbook there are no rules, so no mention", ctx do
      refute Verified.verify_prompt(submit(ctx), ctx.board) =~ "every other instance"
    end

    test "a resubmission flags a class of problem once, with every instance", ctx do
      submit(ctx)
      {:ok, _} = decide(ctx, "reject", %{"reason" => "bar 1: no", "checks" => ["bar:1=fail"]})

      {:ok, card} =
        Boards.update_card(
          Repo.get!(Card, ctx.card.id),
          %{"completed" => true, "evidence" => "again", "evidence_commit" => "def5678"},
          actor: ctx.builder,
          by: ctx.owner
        )

      prompt = Verified.verify_prompt(card, ctx.board)

      assert prompt =~
               "Flag a class of problem once: under one part, with every instance of it you find"

      refute prompt =~ "not every instance"
    end
  end
end
