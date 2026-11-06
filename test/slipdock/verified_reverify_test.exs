defmodule Slipdock.VerifiedReverifyTest do
  @moduledoc """
  Partial re-verify (#1944): a card resubmitted after a rejection is judged
  on what failed and what the commits since touch. Its verify prompt carries
  the last verdict and the commit it judged; a part that passed then and
  isn't judged again is recorded as carried from that commit; an acceptance
  is still refused when a judged part fails; the first verification and
  audits are as they were.
  """
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Actor, Boards, Repo, Verified}
  alias Slipdock.Boards.Card
  alias Slipdock.Verified.Checks

  @first "aaaa1111bbbb2222"
  @second "cccc3333dddd4444"

  setup do
    owner = user_fixture("reverify-owner@example.com")
    board = board_fixture(%{"name" => "Reverify", "code" => unique_code()}, owner: owner)

    {:ok, board} =
      Boards.update_board(board, %{"verify_work" => true, "verify_pool" => "checkers"})

    doing = Enum.find(board.columns, &(&1.category == "doing"))
    card = card_fixture(doing, %{"title" => "Export", "bar" => "1. CSV\n2. Header row"})

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

  defp submit(ctx, sha) do
    {:ok, card} =
      Boards.update_card(
        Repo.get!(Card, ctx.card.id),
        %{"completed" => true, "evidence" => "built it", "evidence_commit" => sha},
        actor: ctx.builder,
        by: ctx.owner
      )

    assert card.verify_state == "pending"
    card
  end

  defp decide(ctx, decision, params) do
    Verified.decide(Repo.get!(Card, ctx.card.id), decision, params, ctx.checker, ctx.owner)
  end

  defp reject_first(ctx) do
    submit(ctx, @first)

    {:ok, card} =
      decide(ctx, "reject", %{
        "reason" => "bar 2: no header row",
        "checks" => ["ask=ok", "bar:1=ok", "bar:2=fail:no header row", "rule:UX-4=ok"]
      })

    card
  end

  defp bodies(card),
    do: Boards.get_card!(card.id).comments |> Enum.sort_by(& &1.id) |> Enum.map(& &1.body)

  defp verify_job_prompts(card) do
    import Ecto.Query

    from(j in Slipdock.Runners.Job,
      where: j.card_id == ^card.id and j.kind == "verify",
      order_by: [asc: j.id],
      select: j.prompt
    )
    |> Repo.all()
  end

  describe "the first verification" do
    test "its prompt is as before: nothing judged earlier, nothing to carry", ctx do
      card = submit(ctx, @first)
      assert Verified.previous_verdict(card) == nil

      prompt = Verified.verify_prompt(card, ctx.board)
      refute prompt =~ "judged before"
      refute prompt =~ "carried"
      refute prompt =~ "Flag a class of problem once"
      assert prompt =~ "Another agent did the work and submitted it."
      assert prompt =~ "beyond your decision.\n\nWhat the card asks"
    end

    test "its verdict keeps the commit it judged, and carries nothing", ctx do
      submit(ctx, @first)
      {:ok, card} = decide(ctx, "accept", %{"checks" => ["ask=ok", "bar:1=ok"]})

      assert card.verify_checks["judged_at"] == @first
      assert card.verify_checks["decision"] == "accept"
      refute Map.has_key?(card.verify_checks, "carried")
      refute Enum.any?(card.verify_checks["bar"], &Map.has_key?(&1, "carried_from"))
    end

    test "the commit the verifier names wins over the evidence's", ctx do
      submit(ctx, @first)

      {:ok, card} =
        decide(ctx, "reject", %{
          "reason" => "bar 1: no",
          "commit" => "aaaa1111",
          "checks" => ["bar:1=fail"]
        })

      assert card.verify_checks["judged_at"] == "aaaa1111"
    end

    test "`carried` with no earlier verdict is refused: there is nothing to carry", ctx do
      submit(ctx, @first)

      assert {:error, :unprocessable_entity, msg} =
               decide(ctx, "accept", %{"checks" => ["ask=ok", "bar:1=carried"]})

      assert msg =~ "nothing to carry bar 1"
      assert Repo.get!(Card, ctx.card.id).verify_state == "pending"
    end

    test "a verdict with no commit keeps nothing to carry from", ctx do
      {:ok, card} =
        Boards.update_card(ctx.card, %{"completed" => true, "evidence" => "no sha"},
          actor: ctx.builder,
          by: ctx.owner
        )

      {:ok, card} =
        Verified.decide(
          card,
          "reject",
          %{"reason" => "bar 1: no", "checks" => ["bar:1=fail", "bar:2=ok"]},
          ctx.checker,
          ctx.owner
        )

      refute Map.has_key?(card.verify_checks, "judged_at")

      card = submit(ctx, @second)
      assert Verified.previous_verdict(card) == nil
      refute Verified.verify_prompt(card, ctx.board) =~ "judged before"
    end
  end

  describe "a resubmission's prompt" do
    test "carries the last verdict, its commit, and how to judge only what changed", ctx do
      reject_first(ctx)
      card = submit(ctx, @second)

      assert %{sha: @first, accepted: false, rejections: 1, reason: reason} =
               Verified.previous_verdict(card)

      assert reason =~ "bar 2: no header row"

      prompt = Verified.verify_prompt(card, ctx.board)

      assert prompt =~
               "This card was judged before, at commit #{@first}, and sent back (rejected 1×)"

      assert prompt =~ "The last verdict's reason: bar 2: no header row"
      assert prompt =~ "- bar 2: fail — no header row"
      assert prompt =~ "- bar 1: ok"
      assert prompt =~ "`git diff --name-only #{@first} #{@second}`"
      assert prompt =~ "`git fetch origin #{@first}`"
      assert prompt =~ "Judge every part that failed, and any part whose files"
      assert prompt =~ "carried from aaaa111"
      assert prompt =~ "Passed then: the ask, bar 1, UX-4."
      assert prompt =~ "Never raise again a part that passed or that the new commits fixed."
      assert prompt =~ "Flag a class of problem once"
      assert prompt =~ "name what changed since the last rejection"
    end

    test "is the one the queued verify job gets", ctx do
      reject_first(ctx)
      card = submit(ctx, @second)

      assert [first, again] = verify_job_prompts(card)
      refute first =~ "judged before"
      assert again =~ "judged before, at commit #{@first}"
    end

    test "after a failed merge, says it had been accepted, not rejected", ctx do
      %Card{} = submitted = submit(ctx, @second)

      card = %{
        submitted
        | verify_checks: %{
            "ask" => "ok",
            "bar" => [%{"item" => "1", "result" => "ok"}],
            "judged_at" => @first,
            "decision" => "accept"
          }
      }

      assert %{accepted: true, reason: nil} = Verified.previous_verdict(card)
      prompt = Verified.verify_prompt(card, ctx.board)
      assert prompt =~ "sent back after its merge failed (it had been accepted)"
      assert prompt =~ "**Merge failed** comment"
    end

    test "with nothing passed earlier, says there is nothing to carry", ctx do
      submit(ctx, @first)
      {:ok, _} = decide(ctx, "reject", %{"reason" => "bar 1: no", "checks" => ["bar:1=fail"]})
      card = submit(ctx, @second)

      assert Verified.verify_prompt(card, ctx.board) =~
               "passed no part, so there is nothing to carry"
    end
  end

  describe "a resubmission's verdict" do
    test "records what passed before and wasn't judged again as carried from that commit", ctx do
      reject_first(ctx)
      submit(ctx, @second)

      {:ok, card} =
        decide(ctx, "accept", %{
          "reason" => "header row there",
          "checks" => ["bar:2=ok", "bar:1=carried"]
        })

      checks = card.verify_checks
      assert checks["judged_at"] == @second
      assert checks["ask"] == "ok"
      assert checks["carried"] == %{"ask" => @first}

      assert Enum.sort_by(checks["bar"], & &1["item"]) == [
               %{"item" => "1", "result" => "ok", "carried_from" => @first},
               %{"item" => "2", "result" => "ok"}
             ]

      assert [%{"id" => "UX-4", "result" => "ok", "carried_from" => @first}] = checks["rules"]

      assert List.last(bodies(card)) =~ "- bar 1: ok — carried from aaaa111"
      assert List.last(bodies(card)) =~ "- the ask: ok — carried from aaaa111"
      refute List.last(bodies(card)) =~ "- bar 2: ok — carried"

      assert {"bar 1", "ok", "carried from aaaa111"} in Checks.lines(checks)
    end

    test "a part judged again stands as judged, not carried", ctx do
      reject_first(ctx)
      submit(ctx, @second)

      {:ok, card} =
        decide(ctx, "accept", %{"checks" => ["bar:1=ok:re-read, the CSV moved", "bar:2=ok"]})

      bar1 = Enum.find(card.verify_checks["bar"], &(&1["item"] == "1"))
      assert bar1 == %{"item" => "1", "result" => "ok", "note" => "re-read, the CSV moved"}
    end

    test "an acceptance is still refused when a judged part fails", ctx do
      reject_first(ctx)
      submit(ctx, @second)

      assert {:error, :unprocessable_entity, msg} =
               decide(ctx, "accept", %{"checks" => ["bar:2=fail:still no header"]})

      assert msg =~ "bar 2"
      assert Repo.get!(Card, ctx.card.id).verify_state == "pending"
    end

    test "a part that failed can't be carried", ctx do
      reject_first(ctx)
      submit(ctx, @second)

      assert {:error, :unprocessable_entity, msg} =
               decide(ctx, "accept", %{"checks" => ["bar:2=carried"]})

      assert msg =~ "bar 2 didn't pass at aaaa111, so it can't be carried: judge it"
      assert Repo.get!(Card, ctx.card.id).verify_state == "pending"
    end

    test "a second rejection carries the passed parts into the next round", ctx do
      reject_first(ctx)
      submit(ctx, @second)

      {:ok, card} =
        decide(ctx, "reject", %{
          "reason" => "bar 2: header row misspelt",
          "checks" => ["bar:2=fail:misspelt"]
        })

      assert card.verify_checks["judged_at"] == @second
      assert Enum.find(card.verify_checks["bar"], &(&1["item"] == "1"))["carried_from"] == @first

      again = submit(ctx, "eeee5555")
      prompt = Verified.verify_prompt(again, ctx.board)
      assert prompt =~ "judged before, at commit #{@second}, and sent back (rejected 2×)"
      assert prompt =~ "- bar 1: ok — carried from aaaa111"
      assert prompt =~ "Passed then: the ask, bar 1, UX-4."
    end
  end

  describe "audits are unchanged" do
    setup ctx do
      reject_first(ctx)
      submit(ctx, @second)
      {:ok, card} = decide(ctx, "accept", %{"checks" => ["bar:2=ok"]})
      %{accepted: card}
    end

    test "an audit's prompt judges every part and carries nothing", ctx do
      prompt = Verified.audit_prompt(ctx.accepted, ctx.board)
      assert prompt =~ "judge the work afresh"
      refute prompt =~ "judged before, at commit"
      refute prompt =~ "Carry the rest"
      refute prompt =~ "=carried"
    end

    test "an audit can't carry a part", ctx do
      assert {:error, :unprocessable_entity, msg} =
               Verified.decide(
                 ctx.accepted,
                 "agree",
                 %{"reason" => "fine", "checks" => ["bar:1=carried", "bar:2=ok"]},
                 Actor.web(ctx.owner),
                 ctx.owner
               )

      assert msg =~ "an audit judges every part"

      assert {:ok, _} =
               Verified.decide(
                 ctx.accepted,
                 "agree",
                 %{"reason" => "fine", "checks" => ["bar:1=ok", "bar:2=ok"]},
                 Actor.web(ctx.owner),
                 ctx.owner
               )
    end
  end

  describe "Checks.carry/3" do
    test "carries passed parts the verdict leaves out, and refuses `carried` on a failed one" do
      prior = %{
        "ask" => "ok",
        "bar" => [%{"item" => "1", "result" => "ok"}, %{"item" => "2", "result" => "fail"}],
        "rules" => [%{"id" => "UX-4", "result" => "n/a"}, %{"id" => "UX-5", "result" => "broken"}],
        "handbook_line" => "disputed",
        "suite" => %{"passed" => 3, "failed" => 0}
      }

      assert Checks.passed_parts(prior) == [{"ask", nil}, {"bar", "1"}, {"rules", "UX-4"}]

      assert {:ok, checks} =
               Checks.carry(%{"bar" => [%{"item" => "2", "result" => "ok"}]}, prior, "abc")

      refute Map.has_key?(checks, "suite")
      refute Map.has_key?(checks, "handbook_line")
      assert checks["rules"] == [%{"id" => "UX-4", "result" => "n/a", "carried_from" => "abc"}]

      assert {:error, msg} = Checks.carry(%{"handbook_line" => "carried"}, prior, "abc")
      assert msg =~ "the Handbook line didn't pass"

      assert {:ok, %{}} == Checks.carry(%{}, nil, nil)
      assert {:ok, %{"ask" => "ok"}} == Checks.carry(%{"ask" => "ok"}, prior, nil)
    end

    test "parses `carried` for the ask, a bar item, a rule and the Handbook line" do
      assert {:ok, checks} =
               Checks.parse([
                 "ask=carried",
                 "bar:1=carried",
                 "rule:ux-4=carried",
                 "handbook=carried"
               ])

      assert Checks.carried_asks(checks) == [
               {"ask", nil},
               {"bar", "1"},
               {"rules", "UX-4"},
               {"handbook_line", nil}
             ]

      assert {:error, _} = Checks.parse(["suite=carried"])
    end

    test "the stored map, given back with its server-set keys, parses" do
      assert {:ok, checks} =
               Checks.parse(%{
                 "ask" => "ok",
                 "judged_at" => "abc",
                 "decision" => "accept",
                 "carried" => %{"ask" => "abc"},
                 "bar" => [%{"item" => "1", "result" => "ok", "carried_from" => "abc"}]
               })

      assert checks == %{"ask" => "ok", "bar" => [%{"item" => "1", "result" => "ok"}]}
    end
  end
end
