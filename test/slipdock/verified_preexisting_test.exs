defmodule Slipdock.VerifiedPreexistingTest do
  @moduledoc """
  Pre-existing rule hits (#1945): a rule broken only in code the diff didn't
  change is a third state beside pass and fail, `pre-existing`, with the
  file and line. It never makes a rejection, an acceptance may carry it,
  and each is kept as a `rule` finding on the card (source `verification`),
  once per part. The rejection-limit wait lists what failed each time and
  asks whether the approach, not the fix, is wrong.
  """
  use Slipdock.DataCase, async: true

  import Ecto.Query
  import Slipdock.Fixtures

  alias Slipdock.{Actor, Boards, Repo, Verified}
  alias Slipdock.Boards.Card
  alias Slipdock.Findings.Finding
  alias Slipdock.Verified.Checks

  setup do
    owner = user_fixture("preexisting-owner@example.com")
    board = board_fixture(%{"name" => "Inherited", "code" => unique_code()}, owner: owner)
    {:ok, board} = Boards.update_board(board, %{"verify_work" => true})
    doing = Enum.find(board.columns, &(&1.category == "doing"))
    card = card_fixture(doing, %{"title" => "Export"})

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
      Boards.Cards.update_card(
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

  defp findings(card),
    do: Repo.all(from(f in Finding, where: f.card_id == ^card.id, order_by: f.id))

  defp bodies(card),
    do: Boards.Cards.get_card!(card.id).comments |> Enum.sort_by(& &1.id) |> Enum.map(& &1.body)

  describe "Checks.parse/1" do
    test "a pre-existing rule part takes its file and line, and an optional why" do
      assert {:ok, %{"rules" => [rule]}} =
               Checks.parse(["rule:ux-4=pre-existing:lib/card.ex:42:hex colour"])

      assert rule == %{
               "id" => "UX-4",
               "result" => "pre-existing",
               "file" => "lib/card.ex",
               "line" => 42,
               "note" => "hex colour"
             }

      assert {:ok, %{"rules" => [%{"file" => "lib/a.ex", "line" => 7} = bare]}} =
               Checks.parse(["rule:UX-4=pre-existing:lib/a.ex:7"])

      refute Map.has_key?(bare, "note")
    end

    test "the stored map is taken back, its place included" do
      stored = %{
        "rules" => [
          %{
            "id" => "UX-4",
            "result" => "pre-existing",
            "file" => "lib/a.ex",
            "line" => 7,
            "note" => "x"
          }
        ]
      }

      assert {:ok, ^stored} = Checks.parse(stored)
    end

    test "without a file and line it is refused, saying how it should read" do
      for bad <- [
            "rule:UX-4=pre-existing",
            "rule:UX-4=pre-existing:lib/a.ex",
            "rule:UX-4=pre-existing:why"
          ] do
        assert {:error, msg} = Checks.parse([bad])
        assert msg =~ "needs the file and line where it is broken"
        assert msg =~ "`rule:UX-4=pre-existing:lib/foo.ex:42[:why]`"
      end
    end

    test "is neither failing nor blocking, and shows with its place" do
      {:ok, checks} =
        Checks.parse(["bar:1=ok", "rule:UX-4=pre-existing:lib/a.ex:7:hex", "rule:UX-5=ok"])

      assert Checks.failing(checks) == []
      assert Checks.blocking(checks) == []
      refute Checks.failing_result?("pre-existing")
      assert {"UX-4", "pre-existing", "lib/a.ex:7; hex"} in Checks.lines(checks)
      assert [%{"id" => "UX-4"}] = Checks.pre_existing(checks)
      # Not a passed part either: a later round judges it again.
      assert Checks.passed_parts(checks) == [{"bar", "1"}, {"rules", "UX-5"}]
    end
  end

  describe "a verdict with pre-existing parts" do
    test "and no failing part is an acceptance, recorded as a rule finding once per part", ctx do
      submit(ctx)

      assert {:ok, card} =
               decide(ctx, "accept", %{
                 "reason" => "all met",
                 "checks" => [
                   "bar:1=ok",
                   "rule:UX-4=pre-existing:lib/card.ex:42:hex colour",
                   "rule:UX-4=pre-existing:lib/card.ex:42:hex colour",
                   "rule:ARCH-3=pre-existing:lib/boards.ex:9"
                 ]
               })

      assert card.verify_state == "accepted"
      assert card.completed

      assert [ux4, arch3] = findings(card)
      assert ux4.kind == "rule"
      assert ux4.source == "verification"
      assert ux4.cause == "pre-existing UX-4 lib/card.ex:42"

      assert ux4.text =~
               "UX-4 is broken in code the change didn't touch, at lib/card.ex:42: hex colour"

      assert ux4.count == 1
      assert arch3.cause == "pre-existing ARCH-3 lib/boards.ex:9"

      assert List.last(bodies(card)) =~ "- UX-4: pre-existing — lib/card.ex:42; hex colour"
    end

    test "names no failing part, so a rejection on it alone is refused, and says why", ctx do
      submit(ctx)

      assert {:error, :unprocessable_entity, msg} =
               decide(ctx, "reject", %{
                 "reason" => "UX-4 is broken",
                 "checks" => ["rule:UX-4=pre-existing:lib/card.ex:42"]
               })

      assert msg =~ "a rejection names what fails"
      assert msg =~ "(`pre-existing`) is never a rejection"
      assert Repo.get!(Card, ctx.card.id).verify_state == "pending"
      assert findings(ctx.card) == []
    end

    test "beside a failing part is still a rejection, the pre-existing one kept as a finding",
         ctx do
      submit(ctx)

      assert {:ok, card} =
               decide(ctx, "reject", %{
                 "reason" => "bar 1: no CSV",
                 "checks" => ["bar:1=fail:no CSV", "rule:UX-4=pre-existing:lib/card.ex:42"]
               })

      assert card.verify_state == "rejected"
      causes = card |> findings() |> Enum.map(&{&1.source, &1.cause})
      assert {"verification", "pre-existing UX-4 lib/card.ex:42"} in causes
      assert {"rejection", "rejected: bar 1"} in causes
    end

    test "reported again on the next round counts the same finding", ctx do
      submit(ctx)

      {:ok, _} =
        decide(ctx, "reject", %{
          "reason" => "bar 1: no",
          "checks" => ["bar:1=fail", "rule:UX-4=pre-existing:lib/card.ex:42"]
        })

      submit(ctx)

      {:ok, card} =
        decide(ctx, "accept", %{"checks" => ["bar:1=ok", "rule:UX-4=pre-existing:lib/card.ex:42"]})

      assert [%{count: 2}] = card |> findings() |> Enum.filter(&(&1.source == "verification"))
    end

    test "with no pre-existing part records none", ctx do
      submit(ctx)
      {:ok, card} = decide(ctx, "accept", %{"checks" => ["bar:1=ok", "rule:UX-4=ok"]})
      assert findings(card) == []
    end
  end

  describe "the prompts" do
    test "verify and audit, on a board with a handbook, say when to use pre-existing", ctx do
      {:ok, _} = Slipdock.Handbook.install(ctx.owner, ctx.board)
      board = Boards.get_board!(ctx.board.id)
      card = submit(ctx)

      verify = Verified.verify_prompt(card, board)
      assert verify =~ Verified.pre_existing_sentence()
      assert verify =~ "`rule:<id>=ok|broken|n/a|pre-existing:<file>:<line>`"

      {:ok, accepted} = decide(ctx, "accept", %{"checks" => ["bar:1=ok"]})
      audit = Verified.audit_prompt(accepted, board)
      assert audit =~ Verified.pre_existing_sentence()

      assert Verified.pre_existing_sentence() =~
               "A rule broken only in lines the diff didn't change is not the builder's"

      assert Verified.pre_existing_sentence() =~ "never as a reason to reject"
    end

    test "without a handbook there are no rules to judge, so no mention", ctx do
      refute Verified.verify_prompt(submit(ctx), ctx.board) =~ "pre-existing"
    end
  end

  describe "the rejection limit's wait (#1945)" do
    test "lists what failed in each rejection and asks about the approach; its choices are unchanged",
         ctx do
      {:ok, _} = Boards.update_board(ctx.board, %{"verify_rejection_limit" => 2})

      for {reason, checks} <- [
            {"bar 2: no header", ["bar:2=fail:no header", "rule:UX-4=broken"]},
            {"bar 2: header misspelt", ["bar:2=fail:misspelt"]},
            {"bar 2: still", []}
          ] do
        submit(ctx)
        params = %{"reason" => reason}
        params = if checks == [], do: params, else: Map.put(params, "checks", checks)
        {:ok, _} = decide(ctx, "reject", params)
      end

      card = Repo.get!(Card, ctx.card.id)
      wait = Repo.get_by(Boards.Wait, card_id: card.id)

      assert wait.choices == ["Rework as rejected", "Accept as is"]
      assert wait.needs =~ "was rejected 3 times (the board allows 2)"
      assert wait.needs =~ "Failed each time: 1. bar 2, UX-4; 2. bar 2; 3. bar 2."
      assert wait.needs =~ "The approach may be wrong, not the fix"
      assert wait.needs =~ "you can edit the bar before you answer"
      assert String.length(wait.needs) < 1000

      reasons = Enum.find(bodies(card), &(&1 =~ "**Rejected 3 times**"))
      assert reasons =~ "1. bar 2: no header (failed: bar 2, UX-4)"
      assert reasons =~ "3. bar 2: still (failed: bar 2)"
      assert reasons =~ "bar 2 failed more than once."
      assert reasons =~ "The approach may be wrong, not the fix"
    end

    test "a long history is cut to fit the wait", ctx do
      {:ok, _} = Boards.update_board(ctx.board, %{"verify_rejection_limit" => 1})
      many = Enum.map_join(1..60, "\n", &"bar:#{&1}=fail")

      for _ <- 1..2 do
        submit(ctx)
        {:ok, _} = decide(ctx, "reject", %{"reason" => "bar 1: lots", "checks" => many})
      end

      wait = Repo.get_by(Boards.Wait, card_id: ctx.card.id)
      assert wait.needs =~ "…"
      assert wait.needs =~ "The approach may be wrong, not the fix"
      assert String.length(wait.needs) < 1000
    end

    test "rounds that each failed on something else say so", ctx do
      {:ok, _} = Boards.update_board(ctx.board, %{"verify_rejection_limit" => 1})

      for n <- 1..2 do
        submit(ctx)

        {:ok, _} =
          decide(ctx, "reject", %{"reason" => "bar #{n}: no", "checks" => ["bar:#{n}=fail"]})
      end

      reasons = Enum.find(bodies(ctx.card), &(&1 =~ "**Rejected 2 times**"))
      assert reasons =~ "Each round failed on something else."
    end
  end
end
